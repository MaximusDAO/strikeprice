
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CoveredOptionContract {

    struct CoveredOption {
        bool isAmericanStyleOption; // if American style, the option may be exercised at any time. If European, it can only be exercised after expiry and before redemption phase.
        uint256 strikePrice; // premium token units / collateral token units
        uint256 writingPhaseEndTimestamp; // during the writing phase is when the premium token and collateral token can be deposited.
        uint256 expiryTimestamp; // after the expiry, the redemption phase starts if 
        uint256 exercisePhaseDuration; // if American style, will be 0. If European style, this is the time between option expiry and redemption phase. This is when the option may be exercised.
        address premiumTokenAddress; // The token that the premium is paid in and the purchase is made with during exercise.
        address collateralTokenAddress; // The token that the option holder has the option to buy.
        address optionContractAddress; // The contract address for token which may be used to exercise the option.
        address collateralContractAddress; // the contract address for the token which is backed by either the collateral, or the proceeds of the collateral purchases through option exercise.
        uint256 premiumPerCollateral; // The ratio between premium tokens deposited and collateral tokens deposited during option writing phase.
        uint256 lateDepositThresholdBasisPoints; // The percent change of deposit which would trigger an extension of the writing period.
        uint256 lateDepositExtensionDuration; // The number of seconds that an option writing period may be extended by
    }
    uint256 OPTION_ID;
    address CLEARINGHOUSE_ADDRESS;
    uint8 DECIMALS;
    
    function getPhase() public view returns (uint256 stageId) {
        // 0: Option Writing phase - premium and collateral can be deposited
        // 1: Trading Phase - Option token and Collateral token can be traded
        // 2: Exercise Phase - period of time when options can be exercised
        // 3: Redemption Phase - period where Collateral token is redeemable for the funds in the collateral contract.
        CoveredOption memory option = ClearingHouse(CLEARINGHOUSE_ADDRESS).getOptionData(OPTION_ID);
        if (block.timestamp < option.writingPhaseEndTimestamp) {
            return 0;
        }
        else if (block.timestamp < option.expiryTimestamp) {
            return 1;
        }
        else if (block.timestamp < option.expiryTimestamp+option.exercisePhaseDuration) {
            return 2;
        }
        else {
            return 3;
        }
    }
        
    
}
contract Option is ERC20, ReentrancyGuard, CoveredOptionContract {
    constructor(string memory name, string memory symbol, uint256 optionId, address clearing_house, uint8 d) ERC20(name, symbol) ReentrancyGuard() {
        OPTION_ID = optionId;
        CLEARINGHOUSE_ADDRESS = clearing_house;
        DECIMALS = d;
    }
    event PremiumDeposit(address indexed depositor, uint256 amount);
    function depositPremium(uint256 amount) public nonReentrant {
        CoveredOption memory option = ClearingHouse(CLEARINGHOUSE_ADDRESS).getOptionData(OPTION_ID);
        
        require(getPhase()==0, "Writing phase has ended.");
        if (block.timestamp > option.writingPhaseEndTimestamp - option.lateDepositExtensionDuration) {
            uint256 current_supply = totalSupply();
            uint256 delta = 10000*amount/current_supply;
            if (delta > option.lateDepositThresholdBasisPoints) {
                option.writingPhaseEndTimestamp +=option.lateDepositExtensionDuration;
            }
        }
        // if deposit happens in last X seconds and it increases the supply by Y threshold
        IERC20(option.premiumTokenAddress).transferFrom(msg.sender, option.collateralTokenAddress, amount);
        _mint(msg.sender, amount);
        emit PremiumDeposit(msg.sender, amount);

    }
    function getOptionData() public view returns (CoveredOption memory){
        CoveredOption memory option = ClearingHouse(CLEARINGHOUSE_ADDRESS).getOptionData(OPTION_ID);
        return option;
    }
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }
    
}

contract Collateral is ERC20, ReentrancyGuard, CoveredOptionContract {
    uint256 public COLLATERAL_PER_TOKEN;
    uint256 public PREMIUM_PER_TOKEN;
    mapping (address=>uint256) public unclaimedDeposits;
    event OptionExercised(address indexed user, uint256 amount, uint256 amount_purchased );
    event CollateralDeposit(address indexed depositor, uint256 amount);
    event PremiumCollected(address indexed depositor, uint256 amount);
    event ProceedsClaimed(address indexed user, uint256  premium_token_claimable, uint256 collateral_token_claimable);

    constructor(string memory name, string memory symbol, uint256 optionId, address clearing_house, uint8 d) ERC20(name, symbol) ReentrancyGuard(){
        OPTION_ID = optionId;
        CLEARINGHOUSE_ADDRESS = clearing_house;
        DECIMALS= d;
    }
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function depositCollateral(uint256 amount) public nonReentrant {
        CoveredOption memory option = ClearingHouse(CLEARINGHOUSE_ADDRESS).getOptionData(OPTION_ID);
        require(block.timestamp < option.writingPhaseEndTimestamp, "Writing phase has ended.");
        if (block.timestamp > option.writingPhaseEndTimestamp - option.lateDepositExtensionDuration) {
            uint256 current_supply = totalSupply();
            uint256 delta = 10000*amount/current_supply;
            if (delta > option.lateDepositThresholdBasisPoints) {
                option.writingPhaseEndTimestamp +=option.lateDepositExtensionDuration;
            }
        }
        // if deposit happens in last X seconds and it increases the supply by Y threshold
        IERC20(option.collateralTokenAddress).transferFrom(msg.sender, option.collateralTokenAddress, amount);
        _mint(msg.sender, amount);
        unclaimedDeposits[msg.sender]+=amount;
        option.premiumPerCollateral = (10**DECIMALS) * IERC20(option.premiumTokenAddress).balanceOf(address(this)) / IERC20(option.collateralTokenAddress).balanceOf(address(this));
        PREMIUM_PER_TOKEN = (10**DECIMALS) * IERC20(option.premiumTokenAddress).balanceOf(address(this))/totalSupply();
        COLLATERAL_PER_TOKEN =(10**DECIMALS) * IERC20(option.collateralTokenAddress).balanceOf(address(this))/totalSupply();
        emit CollateralDeposit(msg.sender, amount);
    }
    function collectPremium() public nonReentrant {
        CoveredOption memory option = ClearingHouse(CLEARINGHOUSE_ADDRESS).getOptionData(OPTION_ID);
        uint256 unclaimed = unclaimedDeposits[msg.sender];
        require(unclaimed >0, "No unclaimed premium.");
        uint256 claimable = option.premiumPerCollateral * unclaimed /(10**DECIMALS);
        unclaimedDeposits[msg.sender]=0;
        IERC20(option.premiumTokenAddress).transfer(msg.sender, claimable);
        emit PremiumCollected(msg.sender, claimable);
        
    }
    
    function exerciseOption(uint256 amount) public nonReentrant {
        CoveredOption memory option = ClearingHouse(CLEARINGHOUSE_ADDRESS).getOptionData(OPTION_ID);
        uint256 phase = getPhase();
        if (option.isAmericanStyleOption) {
            require(phase==1 || phase==2, "Must be after writing period and before redemption period.");
        }
        else {
            require(phase==2, "Must be exercise period.");
        }
        
        uint256 purchasable = amount * COLLATERAL_PER_TOKEN;
        uint256 cost = purchasable * option.strikePrice;
        Option optionContract = Option(option.optionContractAddress);
        optionContract.transferFrom(msg.sender, address(0), amount);
        IERC20(option.premiumTokenAddress).transferFrom(msg.sender, address(this), cost);
        IERC20(option.collateralTokenAddress).transfer(msg.sender, purchasable);
        PREMIUM_PER_TOKEN = (10**DECIMALS) * IERC20(option.premiumTokenAddress).balanceOf(address(this))/totalSupply();
        COLLATERAL_PER_TOKEN =(10**DECIMALS) * IERC20(option.collateralTokenAddress).balanceOf(address(this))/totalSupply();
        emit OptionExercised(msg.sender, amount, purchasable);
    }
 
    function claimProceeds(uint256 amount) public nonReentrant {
        CoveredOption memory option = ClearingHouse(CLEARINGHOUSE_ADDRESS).getOptionData(OPTION_ID);
        require(getPhase()==3, "Must be redemption period.");
        
        uint256 premium_token_claimable = PREMIUM_PER_TOKEN * amount/(10**DECIMALS);
        uint256 collateral_token_claimable = COLLATERAL_PER_TOKEN * amount/(10**DECIMALS);
        IERC20(option.premiumTokenAddress).transfer(msg.sender, premium_token_claimable);
        IERC20(option.collateralTokenAddress).transfer(msg.sender, collateral_token_claimable);
        emit ProceedsClaimed(msg.sender, premium_token_claimable, collateral_token_claimable);
        _burn(msg.sender, amount);
        
    }
    
}

contract ClearingHouse is ReentrancyGuard, CoveredOptionContract, Ownable {
    constructor() Ownable(msg.sender) {
        optionWritingPhaseDuration = 7;
        optionExercisePhaseDuration = 7;
        lateDepositExtensionDuration = 3 hours;
        lateDepositThresholdBasisPoints =1000;
    }
    
    function getOptionData(uint256 optionId) public view returns(  CoveredOption memory ){
        return options[optionId];
    }

    // Map each option to an identifier
    mapping(uint256 => CoveredOption) public options;
    uint256 public nextOptionId = 0;

    uint256 public optionWritingPhaseDuration;
    uint256 public optionExercisePhaseDuration;
    uint256 public lateDepositThresholdBasisPoints;
    uint256 public lateDepositExtensionDuration;
    function setParameters(uint256 OptionWritingPhaseDuration, uint256 OptionExercisePhaseDuration, uint256 LateDepositExtensionDuration, uint256 LateDepositThresholdBasisPoints) public onlyOwner {
        optionWritingPhaseDuration = OptionWritingPhaseDuration;
        optionExercisePhaseDuration = OptionExercisePhaseDuration;
        lateDepositExtensionDuration = LateDepositExtensionDuration;
        lateDepositThresholdBasisPoints = LateDepositThresholdBasisPoints;
    }

    function deployOptionAndCollateral(
        uint256 strikePrice,
        uint256 expiryTimestamp,
        address premiumTokenAddress,
        address collateralTokenAddress, bool isAmericanStyleOption) public onlyOwner nonReentrant {
        ERC20 premiumToken = ERC20(premiumTokenAddress);
        ERC20 collateralToken = ERC20(collateralTokenAddress);

        string memory optionName = string(abi.encodePacked("Option to buy ", collateralToken.symbol(), " at ", uint2str(strikePrice), " ", premiumToken.symbol(), " per ", collateralToken.symbol()));
        string memory collateralName = string(abi.encodePacked("Posted ", collateralToken.name()));
        string memory optionSymbol = string(abi.encodePacked("b", collateralToken.symbol(), "@", uint2str(strikePrice),  premiumToken.symbol()));
        string memory collateralSymbol = string(abi.encodePacked("s", collateralToken.symbol(), "@", uint2str(strikePrice),  premiumToken.symbol()));
        
        Option optionContract = new Option(optionName, optionSymbol, nextOptionId, address(this), premiumToken.decimals());
        Collateral collateralContract = new Collateral(collateralName, collateralSymbol, nextOptionId, address(this), collateralToken.decimals());

        CoveredOption memory newOption = CoveredOption({
            strikePrice: strikePrice,
            expiryTimestamp: expiryTimestamp,
            premiumTokenAddress: premiumTokenAddress,
            collateralTokenAddress: collateralTokenAddress,
            optionContractAddress: address(optionContract),
            collateralContractAddress: address(collateralContract),
            writingPhaseEndTimestamp: block.timestamp + (optionWritingPhaseDuration * 1 days),
            exercisePhaseDuration: optionExercisePhaseDuration * 1 days,
            premiumPerCollateral:0,
            lateDepositExtensionDuration:lateDepositExtensionDuration,
            lateDepositThresholdBasisPoints:lateDepositThresholdBasisPoints,
            isAmericanStyleOption: isAmericanStyleOption

            });

        options[nextOptionId] = newOption;
        nextOptionId++;
    }


    function uint2str(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (_i != 0) {
            k = k-1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}