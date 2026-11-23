// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Rebasing wrapper. Holder balances track a global index funded from an owner-deposited reserve.
contract RebasingIndexWrapper {
    uint256 private constant ONE = 1e18;
    uint256 public constant UNWRAP_DELAY = 1 days;

    IERC20 public immutable underlying;
    address public immutable owner;
    uint256 public immutable releaseRatePerSecond;

    uint256 public globalIndex = ONE;
    uint256 public lastIndexTime;
    uint256 public totalPrincipal;
    uint256 public yieldReserve;

    mapping(address => uint256) public principal;
    mapping(address => uint256) public indexSnapshot;
    mapping(address => uint256) public lifetimeYield;
    mapping(address => uint256) public unwrapQueue;
    mapping(address => uint256) public unwrapReadyAt;

    event Wrapped(address indexed user, uint256 amount, uint256 principalMinted);
    event UnwrapRequested(address indexed user, uint256 amount, uint256 readyAt);
    event UnwrapClaimed(address indexed user, uint256 amount);
    event YieldFunded(uint256 amount);
    event IndexAdvanced(uint256 newIndex, uint256 released);

    constructor(IERC20 _underlying, uint256 _releaseRatePerSecond) {
        underlying = _underlying;
        owner = msg.sender;
        releaseRatePerSecond = _releaseRatePerSecond;
        lastIndexTime = block.timestamp;
    }

    function balanceOf(address user) public view returns (uint256) {
        return (principal[user] * globalIndex) / ONE;
    }

    function fundYield(uint256 amount) external {
        require(msg.sender == owner, "not owner");
        require(amount > 0, "zero");
        yieldReserve += amount;
        require(underlying.transferFrom(msg.sender, address(this), amount), "pull");
        emit YieldFunded(amount);
    }

    function _advanceGlobalIndex() internal {
        uint256 dt = block.timestamp - lastIndexTime;
        lastIndexTime = block.timestamp;
        if (dt == 0 || totalPrincipal == 0 || yieldReserve == 0) return;
        uint256 release = releaseRatePerSecond * dt;
        if (release > yieldReserve) release = yieldReserve;
        yieldReserve -= release;
        globalIndex += (release * ONE) / totalPrincipal;
        emit IndexAdvanced(globalIndex, release);
    }

    function _creditIndexedYield(address who) internal {
        _advanceGlobalIndex();
        uint256 earned = (principal[who] * (globalIndex - indexSnapshot[who])) / ONE;
        indexSnapshot[who] = globalIndex;
        lifetimeYield[who] += earned;
    }

    function wrap(uint256 amount) external returns (uint256 minted) {
        require(amount > 0, "zero");
        _creditIndexedYield(msg.sender);
        minted = (amount * ONE) / globalIndex;
        principal[msg.sender] += minted;
        totalPrincipal += minted;
        emit Wrapped(msg.sender, amount, minted);
        require(underlying.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function requestUnwrap(uint256 amount) external {
        require(amount > 0, "zero");
        _creditIndexedYield(msg.sender);
        require(amount <= balanceOf(msg.sender), "insufficient");
        uint256 burn = (amount * ONE + globalIndex - 1) / globalIndex;
        principal[msg.sender] -= burn;
        totalPrincipal -= burn;
        unwrapQueue[msg.sender] += amount;
        unwrapReadyAt[msg.sender] = block.timestamp + UNWRAP_DELAY;
        emit UnwrapRequested(msg.sender, amount, unwrapReadyAt[msg.sender]);
    }

    function claimUnwrap() external returns (uint256 amount) {
        amount = unwrapQueue[msg.sender];
        require(amount > 0, "nothing queued");
        require(block.timestamp >= unwrapReadyAt[msg.sender], "locked");
        unwrapQueue[msg.sender] = 0;
        require(underlying.transfer(msg.sender, amount), "xfer");
        emit UnwrapClaimed(msg.sender, amount);
    }
}
