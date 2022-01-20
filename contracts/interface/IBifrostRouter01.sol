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

/**
 * @notice The Bifrost Router Interface
 */
interface IBifrostRouter01 {
    // Helper payment functions
    function withdrawBNB(uint256 amount) external;

    function withdrawForeignToken(address token) external;

    // Bifrost interface
    function listingFee() external view returns (uint256);

    function launchingFee() external view returns (uint256);

    function earlyWithdrawPenalty() external view returns (uint256);

    // Sales status
    enum Status {
        prepared,
        launched,
        canceled,
        raised,
        failed
    }

    function setStatus(Status status) external;
}
