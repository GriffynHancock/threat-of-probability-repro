// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

error ZeroValue();
error ShortBalance(uint256 available, uint256 requested);
error TokenMoveFailed();

/// @title HalvingBlockEpochBond
/// @notice Epochs are measured in blocks. The emission halves every `halvingEpochs` epochs.
///         Epoch slots are appended lazily by _creditEpochs(), which every entry point calls.
contract HalvingBlockEpochBond {
    uint256 private constant ONE = 1e18;

    /// @notice Record of one closed epoch.
    struct Slot {
        uint64 closedAtBlock;
        uint256 emitted;
        uint256 accPerUnit;
    }

    IERC20 public immutable bondToken;
    IERC20 public immutable yieldToken;
    address public immutable admin;
    uint256 public immutable firstBlock;
    uint256 public immutable blocksPerEpoch;
    uint256 public immutable baseEmission;
    uint256 public immutable halvingEpochs;

    Slot[] public slots;
    uint256 public accPerUnit;
    uint256 public bonded;

    mapping(address => uint256) public bondOf;
    mapping(address => uint256) public indexOf; // accPerUnit at the account's last accrual
    mapping(address => uint256) public unclaimed;

    event Bonded(address indexed holder, uint256 amount);
    event Unbonded(address indexed holder, uint256 amount);
    event Collected(address indexed holder, uint256 amount);
    event SlotClosed(uint256 indexed index, uint256 emitted);

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin only");
        _;
    }

    constructor(
        IERC20 _bond,
        IERC20 _yield,
        uint256 _blocksPerEpoch,
        uint256 _baseEmission,
        uint256 _halvingEpochs
    ) {
        if (_blocksPerEpoch == 0 || _halvingEpochs == 0) revert ZeroValue();
        bondToken = _bond;
        yieldToken = _yield;
        admin = msg.sender;
        firstBlock = block.number;
        blocksPerEpoch = _blocksPerEpoch;
        baseEmission = _baseEmission;
        halvingEpochs = _halvingEpochs;
    }

    function bond(uint256 amount) external {
        if (amount == 0) revert ZeroValue();
        _creditEpochs();
        _accrue(msg.sender);
        _pull(bondToken, msg.sender, amount);
        bondOf[msg.sender] += amount;
        bonded += amount;
        emit Bonded(msg.sender, amount);
    }

    function unbond(uint256 amount) external {
        if (amount == 0) revert ZeroValue();
        _creditEpochs();
        _accrue(msg.sender);
        uint256 have = bondOf[msg.sender];
        if (have < amount) revert ShortBalance(have, amount);
        bondOf[msg.sender] = have - amount;
        bonded -= amount;
        _push(bondToken, msg.sender, amount);
        emit Unbonded(msg.sender, amount);
    }

    function collect() external {
        _creditEpochs();
        _accrue(msg.sender);
        uint256 amount = unclaimed[msg.sender];
        if (amount == 0) revert ZeroValue();
        unclaimed[msg.sender] = 0;
        _push(yieldToken, msg.sender, amount);
        emit Collected(msg.sender, amount);
    }

    function slotCount() external view returns (uint256) {
        return slots.length;
    }

    /// @dev Appends a slot for every epoch boundary that has passed. The emission for slot i
    ///      is baseEmission shifted right by i / halvingEpochs. Slots closed with nothing bonded
    ///      record zero emission.
    function _creditEpochs() internal {
        uint256 target = (block.number - firstBlock) / blocksPerEpoch;
        while (slots.length < target) {
            uint256 idx = slots.length;
            uint256 shifts = idx / halvingEpochs;
            uint256 emission = shifts >= 256 ? 0 : baseEmission >> shifts;
            if (bonded > 0) {
                accPerUnit += emission * ONE / bonded;
            } else {
                emission = 0;
            }
            slots.push(Slot(uint64(block.number), emission, accPerUnit));
            emit SlotClosed(idx, emission);
        }
    }

    /// @dev Converts the global accumulator movement since the account's last accrual into
    ///      unclaimed yield for that account.
    function _accrue(address holder) internal {
        uint256 delta = accPerUnit - indexOf[holder];
        if (delta != 0) {
            unclaimed[holder] += bondOf[holder] * delta / ONE;
        }
        indexOf[holder] = accPerUnit;
    }

    function _pull(IERC20 token, address from, uint256 amount) internal {
        if (!token.transferFrom(from, address(this), amount)) revert TokenMoveFailed();
    }

    function _push(IERC20 token, address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TokenMoveFailed();
    }
}
