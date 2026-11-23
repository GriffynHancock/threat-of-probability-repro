// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

////////////////////////////////////////////////////////////////
//  Share vault with an emission stream and a cooldown exit queue
////////////////////////////////////////////////////////////////

contract CooldownExitVault {
    uint256 internal constant ONE = 1e18;
    uint256 public constant COOLDOWN = 7 days;
    uint256 public constant EMISSION_PER_SECOND = 1e12;

    IERC20 public immutable underlying;
    address public immutable steward;

    uint256 public totalShares;
    uint256 public assetsHeld;
    uint256 public emissionReserve;
    uint256 public lastAccrual;
    uint256 public totalQueued;

    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public queuedOf;
    mapping(address => uint256) public exitReadyAt;

    event Minted(address indexed account, uint256 assets, uint256 shares);
    event ExitRequested(address indexed account, uint256 shares, uint256 assets, uint256 readyAt);
    event ExitClaimed(address indexed account, uint256 assets);
    event Accrued(uint256 amount, uint256 assetsHeld);
    event EmissionsFunded(uint256 amount);

    constructor(IERC20 _underlying) {
        underlying = _underlying;
        steward = msg.sender;
        lastAccrual = block.timestamp;
    }

    function exchangeRate() public view returns (uint256) {
        if (totalShares == 0) return ONE;
        return assetsHeld * ONE / totalShares;
    }

    function fundEmissions(uint256 amount) external {
        require(msg.sender == steward, "steward only");
        _accrue();
        emissionReserve += amount;
        require(underlying.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit EmissionsFunded(amount);
    }

    function mintFor(uint256 assets) external returns (uint256 shares) {
        require(assets > 0, "zero assets");
        _accrue();

        shares = totalShares == 0 ? assets : assets * totalShares / assetsHeld;
        require(shares > 0, "zero shares");

        sharesOf[msg.sender] += shares;
        totalShares += shares;
        assetsHeld += assets;

        require(underlying.transferFrom(msg.sender, address(this), assets), "pull failed");
        emit Minted(msg.sender, assets, shares);
    }

    function requestExit(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "zero shares");
        require(sharesOf[msg.sender] >= shares, "not enough shares");
        _accrue();

        assets = shares * assetsHeld / totalShares;

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        assetsHeld -= assets;

        queuedOf[msg.sender] += assets;
        totalQueued += assets;
        uint256 readyAt = block.timestamp + COOLDOWN;
        if (readyAt > exitReadyAt[msg.sender]) exitReadyAt[msg.sender] = readyAt;

        emit ExitRequested(msg.sender, shares, assets, exitReadyAt[msg.sender]);
    }

    function claimExit() external returns (uint256 assets) {
        assets = queuedOf[msg.sender];
        require(assets > 0, "nothing queued");
        require(block.timestamp >= exitReadyAt[msg.sender], "cooling down");

        queuedOf[msg.sender] = 0;
        totalQueued -= assets;

        require(underlying.transfer(msg.sender, assets), "push failed");
        emit ExitClaimed(msg.sender, assets);
    }

    function _accrue() internal {
        uint256 elapsed = block.timestamp - lastAccrual;
        lastAccrual = block.timestamp;
        if (elapsed == 0 || totalShares == 0) return;

        uint256 due = elapsed * EMISSION_PER_SECOND;
        if (due > emissionReserve) due = emissionReserve;
        emissionReserve -= due;
        assetsHeld += due;
        emit Accrued(due, assetsHeld);
    }
}
