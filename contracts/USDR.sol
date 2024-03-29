//SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.11;

////////////////////////////////////////////////////////////////////////////////////////
//      ...     ..      ..           ..      .         .....                ...       //
//    x*8888x.:*8888: -"888:      x88f` `..x88. .>  .H8888888h.  ~-.    .zf"` `"tu    //
//   X   48888X `8888H  8888    :8888   xf`*8888%   888888888888x  `>  x88      '8N.  //
//  X8x.  8888X  8888X  !888>  :8888f .888  `"`    X~     `?888888hx~  888k     d88&  //
//  X8888 X8888  88888   "*8%- 88888' X8888. >"8x  '      x8.^"*88*"   8888N.  $888F  //
//  '*888!X8888> X8888  xH8>   88888  ?88888< 888>  `-:- X8888x        `88888 9888%   //
//    `?8 `8888  X888X X888>   88888   "88888 "8%        488888>         %888 "88F    //
//    -^  '888"  X888  8888>   88888 '  `8888>         .. `"88*           8"   "*h=~  //
//     dx '88~x. !88~  8888>   `8888> %  X88!        x88888nX"      .   z8Weu         //
//   .8888Xf.888x:!    X888X.:  `888X  `~""`   :    !"*8888888n..  :   ""88888i.   Z  //
//  :""888":~"888"     `888*"     "88k.      .~    '    "*88888888*   "   "8888888*   //
//      "~'    "~        ""         `""*==~~`              ^"***"`          ^"**""    //
//                                                                                    //
////////////////////////////////////////////////////////////////////////////////////////

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title ERC20 token for Metl by RaidGuild
 *
 * @author mpbowes, dcoleman, mkdir, st4rgard3n, penguin, salky
 */

contract USDR is
  Initializable,
  ERC20Upgradeable,
  ERC20BurnableUpgradeable,
  PausableUpgradeable,
  AccessControlEnumerableUpgradeable
{
  // Role for minters
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  // Role for burners
  bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

  // Role for freezers
  bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

  // Role for frozen users
  bytes32 public constant FROZEN_USER = keccak256("FROZEN_USER");

  // Role for pausers
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  // Role for whitelisted users
  bytes32 public constant WHITELIST_USER = keccak256("WHITELIST_USER");

  // Role for the fee controller
  bytes32 public constant FEE_CONTROLLER = keccak256("FEE_CONTROLLER");

  // Role for limited delay enforced minting
  bytes32 public constant LIMITED_MINTER = keccak256("LIMITED_MINTER");

  // Role which blocks burn against DeFi partners
  bytes32 public constant BURN_PROOF = keccak256("BURN_PROOF");

  // Basis Point values
  uint256 public constant BASIS_RATE = 1000000000;

  // Mint transaction cleared by transferId
  event ReceivedMint(address indexed recipient, uint256 indexed amount, bytes32 indexed transferId);

  // Minting fee
  event MintFee(address indexed feeCollector, uint256 indexed fee, bytes32 indexed transferId);

  // Burn transaction initiated by transferId
  event ReceivedBurn(address indexed recipient, uint256 indexed amount, bytes32 indexed actionId);

  // Burning fee
  event BurnFee(address indexed feeCollector, uint256 indexed fee, bytes32 indexed actionId);

  // Limited mint canceled
  event MintVetoed(address indexed recipient, uint256 indexed amount, bytes32 indexed transferId);

  // Limited minting commitment
  event Commit(
    address indexed recipient,
    uint256 indexed amount,
    bytes32 indexed transferId,
    uint256 mintUnlockTime,
    uint256 commitUnlockTime,
    address limitedMinter
  );

  // variableRate determines the protocol fee during mint and burn
  uint256 public variableRate;

  // Address where fees are collected
  address public currentFeeCollector;

  // Flag for allowing mint without paying fees
  bool public freeMinting;

  // Flag for allowing burning without paying fees
  bool public freeBurning;

  // Multiplier that determines cooldown of limited minting
  uint256 public cooldownMultiplier;
  
  // Commitment cooldown
  uint256 public commitCooldown;

  // Commitment hash to timestamp unlock
  mapping(bytes32 => uint256) public mintUnlock;
  
  // Unlock time for a limited minter account
  mapping(address => uint256) public commitUnlock;

  /**
   * @notice Initializes contract and sets state variables
   * Note: no params, just assigns deployer to default_admin_role
   */
  function initialize() public initializer {
    __ERC20_init("USD Receipt", "USDR");
    __ERC20Burnable_init();
    __Pausable_init();
    __AccessControl_init();
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _setRoleAdmin(FROZEN_USER, FREEZER_ROLE);
    variableRate = 1000000; // 1000000 = 0.1%
    freeMinting = true; // Free minting activated
    freeBurning = true; // Free burning activated
    cooldownMultiplier = 9;
    commitCooldown = 180;
  }

  modifier onlyWhitelist(address recipient) {
    require(hasRole(WHITELIST_USER, recipient), "!Whitelist");
    _;
  }

  /**
   * @notice Modify basis point variable rate
   * @param newRate the new variable rate for calculating protocol fees
   */
  function updateVariableRate(uint256 newRate)
    external
    onlyRole(FEE_CONTROLLER)
  {
    // Variable fee must be adjusted in increments of 0.01%
    require(newRate % 100000 == 0, "!Increment");
    // Variable fee max
    require(newRate <= 100000000, "!TooMuch");
    variableRate = newRate;
  }

  /**
  * @notice Set all contract controls
  * @param newFreeBurning flag for free burning
  * @param newFreeMinting flag for free minting
  * @param newCommitCooldown the amount of time delay between limited minting commitments
  * @param newCooldownMultiplier the number of seconds per USDR required for a limited mint commitment to cooldown
  */
  function setControls(
    bool newFreeBurning,
    bool newFreeMinting,
    uint256 newCommitCooldown,
    uint256 newCooldownMultiplier
  )
    external onlyRole(DEFAULT_ADMIN_ROLE) {

    if(newFreeBurning == false || newFreeMinting == false ) {
      require(currentFeeCollector != address(0), "!Collector");
    }

    freeBurning = newFreeBurning;
    freeMinting = newFreeMinting;
    commitCooldown = newCommitCooldown;
    cooldownMultiplier = newCooldownMultiplier;
  }

  /**
  * @notice Set address of fee collector
  * @param feeCollector the address which will collect protocol fees
  */
  function setFeeCollector(address feeCollector) external onlyRole(FEE_CONTROLLER) {
    currentFeeCollector = feeCollector;
  }

  /**
   * @notice Modified Revoke Role for security
   * @param role the target role to revoke
   * @param account the address with role to be revoked
   */
  function revokeRole(bytes32 role, address account) public override {
    if (role == DEFAULT_ADMIN_ROLE) {
      require(getRoleMemberCount(role) > 1, "!Admin");
    }
    super.revokeRole(role, account);
  }

  /**
   * @notice Override preventing frozen accounts and the last admin from renouncing
   * @param role the target role to revoke
   * @param account the address with role to be revoked
   */
  function renounceRole(bytes32 role, address account) public override {
    if (role == FROZEN_USER) {
      require(hasRole(FREEZER_ROLE, msg.sender), "!Frozen");
    }
    if (role == DEFAULT_ADMIN_ROLE) {
      require(getRoleMemberCount(role) > 1, "!Admin");
    }
    super.renounceRole(role, account);
  }

   /**
   * @notice Limited minters must make commitments before minting
   * @param recipient the whitelisted user to mint to
   * @param amount how many tokens to mint
   * @param transferId transfer ID for event logging
   */
  function commitMint(address recipient, uint256 amount, bytes32 transferId)
    external
    onlyRole(LIMITED_MINTER)
    onlyWhitelist(recipient)
  {

    require(commitUnlock[msg.sender] <= block.timestamp || commitUnlock[msg.sender] == 0, "!Commit");
    bytes32 mintHash = _commitmentHash(recipient, amount, transferId);

    require(mintUnlock[mintHash] == 0, "!Queue");

    uint256 unlockTime = block.timestamp + (cooldownMultiplier * (amount / 1 ether));
    mintUnlock[mintHash] = unlockTime;

    uint256 minterCooldown = block.timestamp + commitCooldown;
    commitUnlock[msg.sender] = minterCooldown;

    emit Commit(recipient, amount, transferId, unlockTime, minterCooldown, msg.sender);
  }

  /**
   * @notice Generates hash for the limited minting queue
   * @param _recipient the whitelisted user to mint to
   * @param _amount how many tokens to mint
   * @param _transferId transfer ID for event logging
   */
  function _commitmentHash(address _recipient, uint256 _amount, bytes32 _transferId)
    internal
    pure
    returns(bytes32 _mintHash)
  {
    _mintHash = keccak256(abi.encodePacked(_recipient, _amount, _transferId));
  }

  /**
   * @notice Calculates fees
   * @param _amount how many tokens to mint
   */
  function _calculateFee(uint256 _amount)
    internal
    view
    returns(uint256 _fee)
  {
    require(_amount % BASIS_RATE == 0, "!Precision");
    _fee = (_amount / BASIS_RATE) * variableRate;
  }

  /**
   * @notice Minters may mint tokens to a whitelisted user while incurring fees
   * @param recipient the whitelisted user to mint to
   * @param amount how many tokens to mint
   * @param transferId transfer ID for event logging
   */
  function mint(address recipient, uint256 amount, bytes32 transferId)
    external
    onlyRole(MINTER_ROLE)
    onlyWhitelist(recipient)
  {

    uint256 fee;

    if(freeMinting != true) {
      fee = _calculateFee(amount);
    }

    uint256 adjustedAmount = amount - fee;
    emit ReceivedMint(recipient, adjustedAmount, transferId);
    emit MintFee(currentFeeCollector, fee, transferId);

    if(fee > 0) {
      _mint(currentFeeCollector, fee);
    }

    bytes32 commitmentHash = _commitmentHash(recipient, amount, transferId);
    if(mintUnlock[commitmentHash] != 0) {
      delete mintUnlock[commitmentHash];
    }

    _mint(recipient, adjustedAmount);
  }

    /**
   * @notice Minters may mint tokens to a whitelisted user while incurring fees
   * @param recipient the whitelisted user to mint to
   * @param amount how many tokens to mint
   * @param transferId transfer ID for event logging
   */
  function limitedMint(address recipient, uint256 amount, bytes32 transferId)
    external
    onlyRole(LIMITED_MINTER)
    onlyWhitelist(recipient)
  {

    bytes32 mintHash = _commitmentHash(recipient, amount, transferId);
    require(mintUnlock[mintHash] <= block.timestamp, "!Cooldown");

    uint256 fee;

    if(freeMinting != true) {
      fee = _calculateFee(amount);
    }

    uint256 adjustedAmount = amount - fee;
    emit ReceivedMint(recipient, adjustedAmount, transferId);
    emit MintFee(currentFeeCollector, fee, transferId);

    if(fee > 0) {
      _mint(currentFeeCollector, fee);
    }

    _mint(recipient, adjustedAmount);
    delete mintUnlock[mintHash];
  }

  /**
   * @notice Burners may burn tokens from a pool while incurring fees
   * @param target the address to burn from
   * @param amount how many tokens to burn
   * @param actionId chain originated action id
   */
  function bankBurn(address target, uint256 amount, bytes32 actionId)
    external
    onlyRole(BURNER_ROLE)
  {
    require(!hasRole(BURN_PROOF, target), "!BurnBan");

    uint256 fee;
    if(freeBurning != true) {
      fee = _calculateFee(amount);
    }

    if(fee > 0) {
      _mint(currentFeeCollector, fee);
    }

    emit ReceivedBurn(target, amount, actionId);
    emit BurnFee(currentFeeCollector, fee, actionId);
    _burn(target, amount);
  }

  /**
   * @notice Freezers may cancel pending limited minting
   * @param recipient original recipient
   * @param amount original amount to cancel
   * @param transferId original transfer ID for event logging
   */
  function vetoMint(address recipient, uint256 amount, bytes32 transferId)
    external
    onlyRole(FREEZER_ROLE)
  {
    bytes32 mintHash = _commitmentHash(recipient, amount, transferId);
    uint256 timeToUnlock = mintUnlock[mintHash];

    require(timeToUnlock > 0, "!Commitment");

    delete mintUnlock[mintHash];
    emit MintVetoed(recipient, amount, transferId);
  }

  /**
   * @notice Require users to be unfrozen before allowing a transfer
   * @param sender address tokens will be deducted from
   * @param recipient address tokens will be registered to
   * @param amount how many tokens to send
   */
  function _beforeTokenTransfer(
    address sender,
    address recipient,
    uint256 amount
  ) internal override whenNotPaused {
    require(!hasRole(FROZEN_USER, sender), "!FromFrozen");
    require(!hasRole(FROZEN_USER, recipient), "!ToFrozen");
    super._beforeTokenTransfer(sender, recipient, amount);
  }

  /**
   * @notice Pausers may pause the network
   */
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  /**
   * @notice Pausers may unpause the network
   */
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  /**
   * @notice Override regular external burn
   */
  function burn(uint256 amount) public virtual override(ERC20BurnableUpgradeable) {
    revert();
  }

  /**
   * @notice Override regular external burnFrom
   */
  function burnFrom(address account, uint256 amount) public virtual override(ERC20BurnableUpgradeable) {
    revert();
  }

  /**
   * @notice returns the mint hash
   * @param recipient address
   * @param amount to mint
   * @param transferId identifier
   */
  function getMintHash(address recipient, uint256 amount, bytes32 transferId) public pure returns(bytes32 mintHash) {
    mintHash = _commitmentHash(recipient, amount, transferId);
  }

  // UPGRADE
  // UPGRADE is handled via a transparent proxy network
  // It is not an internal contract call
  // On deploy, the only account able to updgrade the contract is the DEPLOYER
  // DEPLOYER may call transferOwnership(address newOwner) on the contract to TRANSFER OWNERSHIP to the new address
  // THERE IS ONLY EVER ONE OWNER
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/faq#what-is-a-proxy-admin
  // TO UPGRADE:
  // Duplicate this file, change the contract name, and add new code below this block
  // Deploy as normal
}
