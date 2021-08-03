// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./TimeToken.sol";

// MasterChef is the master of TIME. He can make TIME and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once TIME is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of TIME
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTimePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accTimePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. TIME to distribute per block.
        uint256 lastRewardBlock;  // Last block number that TIME distribution occurs.
        uint256 accTimePerShare;   // Accumulated TIME per share, multiplied by 1e18. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The TIME TOKEN!
    TimeToken public time;
    address public devAddress;
    address public feeAddress;
    address public vaultAddress;

    // TIME tokens created per block.
    uint256 public timePerBlock;

    // Max Supply of TIME tokens.
    uint256 public maxSupply;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when TIME mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event SetVaultAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 timePerBlock);
    event SetMaxSupply(address indexed user, uint256 maxSupply);

    constructor(
        TimeToken _time,
        uint256 _startBlock,
        address _devAddress,
        address _feeAddress,
        address _vaultAddress,
        uint256 _maxSupply
    ) public {
        time = _time;
        startBlock = _startBlock;
        devAddress = _devAddress;
        feeAddress = _feeAddress;
        vaultAddress = _vaultAddress;
        maxSupply = _maxSupply;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP) external onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accTimePerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's TIME allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP) external onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending TIME on frontend.
    function pendingTime(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTimePerShare = pool.accTimePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 timeReward = multiplier.mul(timePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accTimePerShare = accTimePerShare.add(timeReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accTimePerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 timeReward = multiplier.mul(timePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accTimePerShare = pool.accTimePerShare.add(timeReward.mul(1e18).div(lpSupply));
        pool.lastRewardBlock = block.number;
        if (time.totalSupply() <= maxSupply) {
          time.mint(devAddress, timeReward.div(10));
          time.mint(address(this), timeReward);
          require(time.totalSupply() <= maxSupply, "ERR: Unable to mint, max supply reached");
        }
    }

    // @dev
    // Owner of MasterChef can call this function to mint all TIME tokens up to the maxSupply cap
    // Function mints only to MasterChef (this address)
    // Intended to be used when TIME reaches 1 hour from maxSupply (through emissions) to mint any un-minted TIME.
    function finalMint() public onlyOwner {
      uint256 finalMintAmount = maxSupply.sub(time.totalSupply());
      time.mint(address(this), finalMintAmount);
      require(finalMintAmount != 0, "ERR: Unable to perform final mint, max supply reached");
      if(finalMintAmount == 0) {
        revert("ERR: Unable to perform Final Mint, max supply reached");
      }
    }

    // Deposit LP tokens to MasterChef for TIME allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accTimePerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safeTimeTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee.div(10).mul(3)); // 30% to Fee Address for Marketing / Dev / Team Salaries (Sustainability)
                pool.lpToken.safeTransfer(vaultAddress, depositFee.div(10).mul(7)); // 70% to Vault Address for Buyback model of TIME
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accTimePerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTimePerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            safeTimeTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTimePerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe TIME transfer function, just in case if rounding error causes pool to not have enough TIME.
    function safeTimeTransfer(address _to, uint256 _amount) internal {
        uint256 timeBal = time.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > timeBal) {
            transferSuccess = time.transfer(_to, timeBal);
        } else {
            transferSuccess = time.transfer(_to, _amount);
        }
        require(transferSuccess, "safeTimeTransfer: Transfer failed");
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) external onlyOwner {
        devAddress = _devAddress;
        emit SetDevAddress(msg.sender, _devAddress);
    }

    function setFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function setVaultAddress(address _vaultAddress) external onlyOwner {
        vaultAddress = _vaultAddress;
        emit SetVaultAddress(msg.sender, _vaultAddress);
    }

    function updateEmissionRate(uint256 _timePerBlock) external onlyOwner {
        massUpdatePools();
        timePerBlock = _timePerBlock;
        emit UpdateEmissionRate(msg.sender, _timePerBlock);
    }

    // Only update before start of farm
    function updateStartBlock(uint256 _startBlock) external onlyOwner {
	    require(startBlock > block.number, "Farm already started");
        startBlock = _startBlock;
    }
}
