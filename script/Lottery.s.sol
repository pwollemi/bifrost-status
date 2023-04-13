// SPDX-License-Identifier: UNLICENSED
// slither-disable-next-line solc-version
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "script/config/LotteryConfig.sol";
import "script/config/ReferralSystemConfig.sol";
import "src/Lottery.sol";
import "test/TestToken.sol";

contract LotteryScript is Script, LotteryConfig, ReferralSystemConfig {
    // solhint-disable-next-line no-empty-blocks
    function setUp() public { }

    function run(address treasury) public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.broadcast(deployerPrivateKey);

        IERC20 token = IERC20(vm.envAddress("REWARD_TOKEN_ADDRESS"));
        getLottery(token, treasury);

        vm.stopBroadcast();
    }
}
