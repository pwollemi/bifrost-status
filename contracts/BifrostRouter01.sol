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
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "contracts/interface/IBifrostRouter01.sol";
import "contracts/interface/IBifrostSale01.sol";
import "contracts/interface/IBifrostSettings.sol";

import "contracts/BifrostSale01.sol";

/**
 * @notice The official Bifrost smart contract
 */
contract BifrostRouter01 is Initializable, OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;

    struct PartnerToken {
        // Whether or not this is a valid partner token
        bool valid;
        // Default 0
        uint128 discount;
    }

    /// @notice 100%
    uint256 public constant TOTAL_PERCENTAGE = 10000;

    /// @notice Bifrost Settings
    IBifrostSettings public bifrostSettings;

    // A mapping of token contract addresses to a flag describing whether or not they can be used to pay a fee
    mapping(address => PartnerToken) public partnerTokens;

    /// @notice A mapping of sale owners to the sales
    mapping(address => BifrostSale01) public sales;

    /// @notice A mapping of wallet addresses to a flag for whether they paid the fee via a partner token or not
    mapping(address => bool) public feePaid;

    /// @notice Emitted when a new sale is created
    event SaleCreated(address indexed runner, address indexed sale);

    enum Status {
        prepared,
        launched,
        canceled,
        raised,
        failed
    }
    event StatusChanged(address indexed sale, Status indexed status);

    function setSatus(Status status) external {
        emit StatusChanged(_msgSender(), status);
    }

    /**
     * @notice The initializer for the router
     */
    function initialize(IBifrostSettings _settings) external initializer {
        __Ownable_init();

        bifrostSettings = _settings;
    }

    /**
     * @notice Forward all received BNB to the owner of the Bifrost Router
     */
    receive() external payable {}

    function setBifrostSettings(IBifrostSettings _settings) external onlyOwner {
        bifrostSettings = _settings;
    }

    /**
     * @notice Reset fee paid status of an account
     */
    function resetFee(address account) external onlyOwner {
        feePaid[account] = false;
    }

    /**
     * @notice Marks the sender as
     */
    function payFee(address token) external {
        PartnerToken memory partnerToken = partnerTokens[token];
        require(partnerToken.valid, "Token not a partner!");

        // Gets the fee in tokens, then takes a percentage discount to incentivize people paying in tokens.
        uint256 feeInToken = bifrostSettings.listingFeeInToken(token);
        uint256 discountedFee = feeInToken
            .mul(TOTAL_PERCENTAGE.sub(uint256(partnerToken.discount)))
            .div(TOTAL_PERCENTAGE);
        TransferHelper.safeTransferFrom(
            token,
            _msgSender(),
            owner(),
            discountedFee
        );
        feePaid[_msgSender()] = true;

        bifrostSettings.increaseDiscounts(feeInToken.sub(discountedFee));
    }

    /**
     * @notice Called by anyone who wishes to begin their own token sale
     */
    function createSale(
        address token,
        address fundToken,
        IBifrostSale01.SaleParams memory saleParams
    ) external payable {
        // Ensure the runner hasn't run a sale before
        //TODO: Add back require(address(sales[_msgSender()]) != address(0), "This wallet is already managing a sale!");

        // Validates the sale config
        bifrostSettings.validate(
            saleParams.soft,
            saleParams.hard,
            saleParams.liquidity,
            saleParams.start,
            saleParams.end,
            saleParams.unlockTime
        );

        // If the person creating the sale hasn't paid the fee, then this call needs to pay the appropriate BNB.
        if (!feePaid[_msgSender()]) {
            require(
                msg.value == bifrostSettings.listingFee(),
                "Not paying the listing fee"
            );
            payable(owner()).transfer(msg.value);
        }

        BifrostSale01 newSale = BifrostSale01(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        bifrostSettings.saleImpl(),
                        bifrostSettings.proxyAdmin(),
                        new bytes(0)
                    )
                )
            )
        );
        newSale.initialize(
            payable(address(this)),
            owner(),
            _msgSender(),
            token,
            fundToken,
            bifrostSettings.exchangeRouter(),
            bifrostSettings.whitelistImpl(),
            bifrostSettings.proxyAdmin(),
            saleParams.unlockTime
        );
        newSale.configure(saleParams);
        sales[_msgSender()] = newSale;

        // Transfer via the Router to avoid taxing
        IERC20Upgradeable(token).transferFrom(
            _msgSender(),
            address(this),
            newSale.totalTokens()
        );
        IERC20Upgradeable(token).transferFrom(
            _msgSender(),
            owner(),
            newSale.saleAmount().mul(bifrostSettings.launchingFee()).div(1e4)
        );

        // Incase tax wasn't disabled, transfer as many tokens as we can and ask the developer to
        // fix this with a topup
        IERC20Upgradeable(token).transfer(
            address(newSale),
            IERC20Upgradeable(token).balanceOf(address(this))
        );

        // Finally, add a fee back so the user can't just keep creating new sales for free
        feePaid[msg.sender] = false;

        // Emit an event
        emit SaleCreated(msg.sender, address(newSale));
    }

    /**
     * @notice To be called by a sales "finalize()" function only
     * @dev
     */
    function launched(
        address payable _sale,
        uint256 _raised,
        uint256 _participants
    ) external {
        require(address(sales[_msgSender()]) == _sale, "Must be owner of sale");

        BifrostSale01 sale = BifrostSale01(_sale);
        require(sale.launched(), "Sale must have launched!");
        bifrostSettings.launch(_sale, _raised, _participants);
    }

    /**
     * @notice Returns the sale of the caller
     */
    function getSale()
        external
        view
        returns (
            address,
            bool,
            address
        )
    {
        return getSaleByOwner(_msgSender());
    }

    /**
     * @notice Returns the sale of a given owner
     */
    function getSaleByOwner(address owner)
        public
        view
        returns (
            address,
            bool,
            address
        )
    {
        return (
            owner,
            address(sales[owner]) != address(0),
            address(sales[owner])
        );
    }

    /**
     * @notice Returns the sale of a given owner
     */
    function listingFee() external view returns (uint256) {
        return bifrostSettings.listingFee();
    }

    /**
     * @notice Returns the sale of a given owner
     */
    function launchingFee() external view returns (uint256) {
        return bifrostSettings.launchingFee();
    }

    /**
     * @notice Returns the sale of a given owner
     */
    function earlyWithdrawPenalty() external view returns (uint256) {
        return bifrostSettings.earlyWithdrawPenalty();
    }

    /**
     * @notice Withdraws BNB from the contract
     */
    function withdrawBNB(uint256 amount) public onlyOwner {
        if (amount == 0) {
            payable(owner()).transfer(address(this).balance);
        } else {
            payable(owner()).transfer(amount);
        }
    }

    /**
     * @notice Withdraws non-RAINBOW tokens that are stuck as to not interfere with the liquidity
     */
    function withdrawForeignToken(address token) external onlyOwner {
        IERC20Upgradeable(token).transfer(
            owner(),
            IERC20Upgradeable(token).balanceOf(address(this))
        );
    }

    /**
     * @notice Add a partner token
     */
    function setPartnerToken(address token, uint128 discount)
        external
        onlyOwner
    {
        partnerTokens[token] = PartnerToken(true, discount);
    }

    /**
     * @notice Removes a partner token
     */
    function removePartnerDiscount(address token) external onlyOwner {
        delete partnerTokens[token];
    }
}
