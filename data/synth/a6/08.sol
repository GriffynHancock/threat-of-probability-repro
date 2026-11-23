// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IHoldingsRegistry {
    function holdingOf(address who) external view returns (uint256);
    function totalHeld() external view returns (uint256);
}

/// Native-currency dividend distributor.
/// Deposits of ETH are spread over the holders recorded by an external registry.
/// Per-holder accounting uses a magnified cumulative figure; a holder's entitlement is realised
/// only when the registry reports a change to that holder, or when the holder withdraws.
contract NativeDividendDistributor {
    uint256 private constant MAGNITUDE = 1 << 128;

    error NoHolders();
    error NothingWithdrawable();
    error OnlyRegistry();
    error TransferReverted();

    event Distributed(uint256 amount, uint256 cumulativePerShare);
    event Realised(address indexed who, uint256 gained, uint256 withdrawableNow);
    event Withdrawn(address indexed who, uint256 amount);

    IHoldingsRegistry public immutable registry;

    uint256 public cumulativePerShare;
    mapping(address => uint256) public baselineOf;
    mapping(address => uint256) public withdrawable;

    constructor(IHoldingsRegistry registry_) {
        registry = registry_;
    }

    receive() external payable {
        _distribute(msg.value);
    }

    /// Registry hook: realise the holder's entitlement before its balance is changed.
    function holdingsChanging(address who) external {
        if (msg.sender != address(registry)) revert OnlyRegistry();
        _realise(who);
    }

    function withdrawDividends() external {
        _realise(msg.sender);
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingWithdrawable();
        withdrawable[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferReverted();
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawableFor(address who) external view returns (uint256) {
        uint256 held = registry.holdingOf(who);
        uint256 fresh = (held * (cumulativePerShare - baselineOf[who])) / MAGNITUDE;
        return withdrawable[who] + fresh;
    }

    function _distribute(uint256 amount) internal {
        uint256 supply = registry.totalHeld();
        if (supply == 0) revert NoHolders();
        cumulativePerShare = cumulativePerShare + (amount * MAGNITUDE) / supply;
        emit Distributed(amount, cumulativePerShare);
    }

    /// Settlement helper for one holder.
    function _realise(address who) internal {
        uint256 current = cumulativePerShare;
        uint256 previous = baselineOf[who];
        baselineOf[who] = current;
        if (current == previous) {
            emit Realised(who, 0, withdrawable[who]);
            return;
        }
        uint256 held = registry.holdingOf(who);
        uint256 gained = (held * (current - previous)) / MAGNITUDE;
        withdrawable[who] = withdrawable[who] + gained;
        emit Realised(who, gained, withdrawable[who]);
    }
}
