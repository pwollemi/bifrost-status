// SPDX-License-Identifier: MIT
//
// Copyright of The $RAINBOW Team
//  ____  _  __               _
// |  _ \(_)/ _|             | |
// | |_) |_| |_ _ __ ___  ___| |_
// |  _ <| |  _| '__/ _ \/ __| __|
// | |_) | | | | | | (_) \__ \ |_
// |____/|_|_| |_|  \___/|___/\__|
//

pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "contracts/interface/uniswap/IUniswapV2Router02.sol";
import "contracts/interface/uniswap/IUniswapV2Factory.sol";
import "contracts/interface/IBifrostRouter01.sol";
import "contracts/interface/IBifrostSale01.sol";
import "contracts/interface/IBifrostSettings.sol";
import "contracts/interface/IERC20Extended.sol";

import "contracts/libraries/TransferHelper.sol";

import "contracts/Whitelist.sol";

/**
 * @notice A Bifrost Sale
 */
contract BifrostSale01 is Initializable, ContextUpgradeable {
    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;

    uint256 public constant ACCURACY = 1e10;

    /// @notice The BifrostRouter owner
    address public owner;

    /// @notice The person running the sale
    address public runner;

    /// @notice The BifrostRouter
    IBifrostRouter01 public bifrostRouter;

    /// @notice The address of the whitelist implementation
    address public whitelistImpl;

    /// @notice The address of the proxy admin
    address public proxyAdmin;

    /// @notice The address of the bifrostRouter
    IUniswapV2Router02 public exchangeRouter;

    /// @notice The address of the LP token
    address public lpToken;

    /**
     * @notice Configuration
     */
    address public tokenA; // The token that the sale is selling
    address public tokenB; // The token that the pay to buy sale tokens
    uint256 public softCap; // The soft cap of BNB or tokenB
    uint256 public hardCap; // The hard cap of BNB or tokenB
    uint256 public min; // The minimum amount of contributed BNB or tokenB
    uint256 public max; // The maximum amount of contributed BNB or tokenB
    uint256 public presaleRate; // How many tokenA is given per BNB or tokenB: no decimal consideration e.g. 1e9(= ACCURACY / 10) means 1 tokenB = 0.1 tokenA,
    uint256 public listingRate; // How many tokenA is worth 1 BNB or 1 tokenB when we list: no decimal consideration
    uint256 public liquidity; // What perecentage of raised funds will be allocated for liquidity (100 = 1% - i.e. out of 10,000)
    uint256 public start; // The start date in UNIX seconds of the presale
    uint256 public end; // The end date in UNIX seconds of the presale
    uint256 public unlockTime; // The time in seconds that the liquidity lock should last
    address public whitelist; // Whitelist contract address
    bool public burn; // Whether or not to burn remaining sale tokens (if false, refunds the sale runner)

    /**
     * @notice State Settings
     */
    bool public prepared; // True when the sale has been prepared to start by the owner
    bool public launched; // Whether the sale has been finalized and launched; inited to false by default
    bool public canceled; // This sale is canceled

    enum Status {
        prepared,
        launched,
        canceled,
        raised,
        failed
    }
    event StatusChanged(address indexed sale, Status indexed status);

    /**
     * @notice Current Status - These are modified after a sale has been setup and is running
     */
    uint256 public totalTokens; // Total tokens determined for the sale
    uint256 public saleAmount; // How many tokens are on sale
    uint256 public liquidityAmount; // How many tokens are allocated for liquidity
    uint256 public raised; // How much BNB has been raised
    mapping(address => uint256) public _deposited; // A mapping of addresses to the amount of BNB they deposited

    /********************** Modifiers **********************/

    /**
     * @notice Checks if the caller is the Bifrost owner, Sale owner or the bifrostRouter itself
     */
    modifier isAdmin() {
        require(
            address(bifrostRouter) == _msgSender() ||
                owner == _msgSender() ||
                runner == _msgSender(),
            "Caller isnt an admin"
        );
        _;
    }

    /**
     * @notice Checks if the sale is running
     */
    modifier isRunning() {
        require(running(), "Sale isn't running!");
        _;
    }

    modifier isSuccessful() {
        require(successful(), "Sale isn't successful!");
        _;
    }

    /**
     * @notice Checks if the sale is finished
     */
    modifier isEnded() {
        require(ended(), "Sale hasnt ended");
        _;
    }

    /**
     * @notice Checks if the sale has been finalized
     */
    modifier isLaunched() {
        require(launched, "Sale hasnt been launched yet");
        _;
    }

    /********************** Functions **********************/

    /**
     * @notice Creates a bifrost sale
     */
    function initialize(
        address _bifrostRouter,
        address _owner,
        address _runner,
        address _tokenA,
        address _tokenB,
        address _exchangeRouter,
        address _whitelistImpl,
        address _proxyAdmin,
        uint256 _unlockTime
    ) external initializer {
        __Context_init();

        // Set the owner of the sale to be the owner of the deployer
        bifrostRouter = IBifrostRouter01(_bifrostRouter);
        owner = _owner;
        runner = _runner;
        tokenA = _tokenA;
        tokenB = _tokenB;

        // Let the bifrostRouter control payments!
        TransferHelper.safeApprove(_tokenA, _bifrostRouter, type(uint256).max);

        exchangeRouter = IUniswapV2Router02(_exchangeRouter);
        whitelistImpl = _whitelistImpl;
        proxyAdmin = _proxyAdmin;
        unlockTime = _unlockTime;

        // TODO: Add a way for the runner to specify this
        burn = true;
    }

    /**
     * @notice Configure a bifrost sale
     */
    function configure(IBifrostSale01.SaleParams memory params)
        external
        isAdmin
    {
        softCap = params.soft;
        hardCap = params.hard;
        min = params.min;
        max = params.max;
        presaleRate = params.presaleRate;
        listingRate = params.listingRate;
        liquidity = params.liquidity;
        start = params.start;
        end = params.end;

        saleAmount = getTokenAAmount(hardCap, presaleRate);
        liquidityAmount = getTokenAAmount(hardCap, listingRate)
            .mul(liquidity)
            .div(1e4);
        totalTokens = saleAmount.add(liquidityAmount);

        if (params.whitelisted) {
            whitelist = address(
                new TransparentUpgradeableProxy(
                    whitelistImpl,
                    proxyAdmin,
                    new bytes(0)
                )
            );
            Whitelist(whitelist).initialize();
        }
    }

    /**
     * @notice If the presale isn't running will direct any received payments straight to the bifrostRouter
     */
    receive() external payable {
        require(tokenB == address(0));
        _deposit(_msgSender(), msg.value);
    }

    function resetWhitelist() external isAdmin {
        if (whitelist != address(0)) {
            whitelist = address(
                new TransparentUpgradeableProxy(
                    whitelistImpl,
                    proxyAdmin,
                    new bytes(0)
                )
            );
            Whitelist(whitelist).initialize();
        }
    }

    function deposited() external view returns (uint256) {
        return accountsDeposited(_msgSender());
    }

    function accountsDeposited(address account) public view returns (uint256) {
        return _deposited[account];
    }

    function setRunner(address _runner) external isAdmin {
        runner = _runner;
    }

    function getRunner() external view returns (address) {
        return runner;
    }

    function isWhitelisted() external view returns (bool) {
        return whitelist != address(0);
    }

    function userWhitelisted() external view returns (bool) {
        return _userWhitelisted(_msgSender());
    }

    function _userWhitelisted(address account) public view returns (bool) {
        if (whitelist != address(0)) {
            return Whitelist(whitelist).isWhitelisted(account);
        } else {
            return false;
        }
    }

    function setWhitelist() external isAdmin {
        require(block.timestamp < start, "Sale started");
        require(whitelist == address(0), "There is already a whitelist!");
        whitelist = address(
            new TransparentUpgradeableProxy(
                whitelistImpl,
                proxyAdmin,
                new bytes(0)
            )
        );
        Whitelist(whitelist).initialize();
    }

    function removeWhitelist() external isAdmin {
        require(block.timestamp < start, "Sale started");
        require(whitelist != address(0), "There isn't a whitelist set");
        whitelist = address(0);
    }

    function addToWhitelist(address[] memory users) external isAdmin {
        require(block.timestamp < end, "Sale ended");
        Whitelist(whitelist).addToWhitelist(users);
    }

    function removeFromWhitelist(address[] memory addrs) external isAdmin {
        require(block.timestamp < start, "Sale started");
        Whitelist(whitelist).removeFromWhitelist(addrs);
    }

    function cancel() external isAdmin {
        require(!launched, "Sale has launched");
        end = block.timestamp;
        canceled = true;
        emit StatusChanged(address(this), Status.canceled);
    }

    /**
     * @notice For users to deposit into the sale
     * @dev This entitles _msgSender() to (amount * presaleRate) after a successful sale
     */
    function deposit(uint256 amount) external payable {
        if (tokenB == address(0)) {
            _deposit(_msgSender(), msg.value);
        } else {
            TransferHelper.safeTransferFrom(
                tokenB,
                msg.sender,
                address(this),
                amount
            );
            _deposit(_msgSender(), amount);
        }
    }

    /**
     * @notice
     */
    function _deposit(address user, uint256 amount) internal {
        require(!canceled, "Sale is canceled");
        require(running(), "Sale isn't running!");
        require(canStart(), "Token balance isn't topped up!");
        require(amount >= min, "Amount must be above min");
        require(amount <= max, "Amount must be below max");

        require(raised.add(amount) <= hardCap, "Cant exceed hard cap");
        require(
            _deposited[user].add(amount) <= max,
            "Cant deposit more than the max"
        );
        if (whitelist != address(0)) {
            require(
                Whitelist(whitelist).isWhitelisted(user),
                "User not whitelisted"
            );
        }
        _deposited[user] = _deposited[user].add(amount);
        raised = raised.add(amount);

        if (!alreadyRaised && raised > softCap) {
            emit StatusChanged(address(this), Status.raised);
            alreadyRaised = true;
        }
    }

    bool alreadyRaised = false;

    /**
     * @notice Finishes the sale, and if successful launches to PancakeSwap
     */
    function finalize() external isAdmin isSuccessful {
        end = block.timestamp;

        // First take the developer cut
        uint256 devTokenB = raised.mul(bifrostRouter.launchingFee()).div(1e4);
        uint256 devTokenA = getTokenAAmount(devTokenB, listingRate);
        if (tokenB == address(0)) {
            TransferHelper.safeTransferETH(owner, devTokenB);
        } else {
            TransferHelper.safeTransfer(tokenB, owner, devTokenB);
        }
        TransferHelper.safeTransfer(tokenA, owner, devTokenA);

        // Find a percentage (i.e. 50%) of the leftover 99% liquidity
        // Dev fee is cut from the liquidity
        uint256 liquidityTokenB = raised.mul(liquidity).div(1e4).sub(devTokenB);
        uint256 tokenAForLiquidity = getTokenAAmount(
            liquidityTokenB,
            listingRate
        );

        // Add the tokens and the BNB to the liquidity pool, satisfying the listing rate as the starting price point
        TransferHelper.safeApprove(
            tokenA,
            address(exchangeRouter),
            tokenAForLiquidity
        );

        if (tokenB == address(0)) {
            exchangeRouter.addLiquidityETH{value: liquidityTokenB}(
                tokenA,
                tokenAForLiquidity,
                0,
                0,
                address(this),
                block.timestamp.add(300)
            );
            lpToken = IUniswapV2Factory(exchangeRouter.factory()).getPair(
                tokenA,
                exchangeRouter.WETH()
            );
        } else {
            TransferHelper.safeApprove(
                tokenB,
                address(exchangeRouter),
                liquidityTokenB
            );
            exchangeRouter.addLiquidity(
                tokenA,
                tokenB,
                tokenAForLiquidity,
                liquidityTokenB,
                0,
                0,
                address(this),
                block.timestamp.add(300)
            );
            lpToken = IUniswapV2Factory(exchangeRouter.factory()).getPair(
                tokenA,
                tokenB
            );
        }

        // Send the sale runner the reamining BNB/tokens
        if (tokenB == address(0)) {
            TransferHelper.safeTransferETH(
                _msgSender(),
                raised.sub(liquidityTokenB).sub(devTokenB)
            );
        } else {
            TransferHelper.safeTransfer(
                tokenB,
                _msgSender(),
                raised.sub(liquidityTokenB).sub(devTokenB)
            );
        }

        // Send the remaining sale tokens
        uint256 soldTokens = getTokenAAmount(raised, presaleRate);
        uint256 remaining = IERC20Upgradeable(tokenA).balanceOf(address(this)) -
            soldTokens;
        if (burn) {
            TransferHelper.safeTransfer(
                tokenA,
                0x000000000000000000000000000000000000dEaD,
                remaining
            );
        } else {
            TransferHelper.safeTransfer(tokenA, msg.sender, remaining);
        }

        launched = true;
        emit StatusChanged(address(this), Status.launched);
    }

    /**
     * @notice For users to withdraw from a sale
     * @dev This entitles _msgSender() to (amount * presaleRate) after a successful sale
     */
    function withdraw() external isEnded {
        require(_deposited[_msgSender()] > 0, "User didnt partake");

        uint256 amount = _deposited[_msgSender()];
        _deposited[_msgSender()] = 0;

        // If the sale was successful, then we give the user their tokens only once the sale has been finalized and launched
        // Otherwise return to them the full amount of BNB/tokens that they pledged for this sale!
        if (successful()) {
            require(launched, "Sale hasnt finalized");
            uint256 tokens = getTokenAAmount(amount, presaleRate);
            TransferHelper.safeTransfer(tokenA, _msgSender(), tokens);
        } else if (failed()) {
            if (tokenB == address(0)) {
                payable(msg.sender).transfer(amount);
            } else {
                IERC20Upgradeable(tokenB).transfer(msg.sender, amount);
            }
        }
    }

    /**
     * @notice For users to withdraw their deposited funds before the sale has been concluded
     * @dev This incurs a tax, where Bifrost will take a cut of this tax
     */
    function earlyWithdraw() external {
        require(!canceled, "Sale is canceled");
        require(running(), "Sale isn't running!");
        require(canStart(), "Token balance isn't topped up!");

        uint256 amount = _deposited[msg.sender];
        _deposited[msg.sender] = _deposited[msg.sender].sub(amount);
        raised = raised.sub(amount);

        // The portion of the deposited tokens that will be taxed
        uint256 taxed = amount.mul(bifrostRouter.earlyWithdrawPenalty()).div(
            1e4
        );
        uint256 returned = amount.sub(taxed);

        if (tokenB == address(0)) {
            payable(msg.sender).transfer(returned);
            payable(owner).transfer(taxed);
        } else {
            IERC20Upgradeable(tokenB).transfer(msg.sender, returned);
            IERC20Upgradeable(tokenB).transfer(owner, taxed);
        }
    }

    /**
     * @notice EMERGENCY USE ONLY: Lets the owner of the sale reclaim any stuck funds
     */
    function reclaim() external isAdmin {
        require(canceled, "Sale hasn't been canceled");
        TransferHelper.safeTransfer(
            tokenA,
            runner,
            IERC20Upgradeable(tokenA).balanceOf(address(this))
        );
    }

    /**
     * @notice Withdraws BNB from the contract
     */
    function emergencyWithdrawBNB() external payable {
        require(owner == _msgSender(), "Only owner");
        payable(owner).transfer(address(this).balance);
    }

    /**
     * @notice Withdraws tokens that are stuck
     */
    function emergencyWithdrawTokens(address _token) external payable {
        require(owner == _msgSender(), "Only owner");
        TransferHelper.safeTransfer(
            tokenA,
            owner,
            IERC20Upgradeable(tokenA).balanceOf(address(this))
        );
    }

    /**
     * @notice Returns true if the admin is able to withdraw the LP tokens
     */
    function canWithdrawLiquidity() public view returns (bool) {
        return end.add(unlockTime) <= block.timestamp;
    }

    /**
     * @notice Lets the sale owner withdraw the LP tokens once the liquidity unlock date has progressed
     */
    function withdrawLiquidity() external isAdmin {
        require(canWithdrawLiquidity(), "Cant withdraw LP tokens yet");
        TransferHelper.safeTransfer(
            lpToken,
            _msgSender(),
            IERC20Upgradeable(lpToken).balanceOf(address(this))
        );
    }

    function successful() public view returns (bool) {
        return raised >= softCap;
    }

    function running() public view returns (bool) {
        return block.timestamp >= start && block.timestamp < end;
    }

    function ended() public view returns (bool) {
        return block.timestamp >= end || launched;
    }

    function failed() public view returns (bool) {
        return block.timestamp >= end || !successful();
    }

    function canStart() public view returns (bool) {
        return
            IERC20Upgradeable(tokenA).balanceOf(address(this)) >= totalTokens;
    }

    function getDecimals(address token) internal view returns (uint256) {
        return token == address(0) ? 18 : IERC20Extended(token).decimals();
    }

    function getTokenAAmount(uint256 tokenBAmount, uint256 rateOfTokenAInTokenB)
        internal
        view
        returns (uint256)
    {
        return
            tokenBAmount
                .mul(rateOfTokenAInTokenB)
                .mul(10**getDecimals(tokenA))
                .div(ACCURACY)
                .div(10**getDecimals(tokenB));
    }

    function getTokenBAmount(uint256 tokenAAmount, uint256 rateOfTokenAInTokenB)
        internal
        view
        returns (uint256)
    {
        return
            tokenAAmount
                .mul(ACCURACY)
                .mul(10**getDecimals(tokenB))
                .div(rateOfTokenAInTokenB)
                .div(10**getDecimals(tokenA));
    }
}
