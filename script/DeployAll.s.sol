// SPDX-License-Identifier: UNLICENSED
// slither-disable-next-line solc-version
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import "script/config/LotteryConfig.sol";
import "script/config/ReferralSystemConfig.sol";
import "script/config/RewardTokenConfig.sol";
import "script/config/RNSourceConfig.sol";

contract DeployAllScript is Script, LotteryConfig, ReferralSystemConfig, RewardTokenConfig, RNSourceConfig {
    // solhint-disable-next-line no-empty-blocks
    function setUp() public { }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        IERC20 token = getRewardToken();
        (ILotteryToken lotteryToken, uint256[] memory percRewardsToPlayers) = getLotteryTokenAndRewardsPerc();
        Lottery lottery = getLottery(token, lotteryToken, percRewardsToPlayers);

        lottery.initSource(getRNSource(address(lottery)));

        vm.stopBroadcast();

        console.log("Lottery deployed at", address(lottery));
        console.log("Lottery token deployed at", address(lotteryToken));
    }
}
