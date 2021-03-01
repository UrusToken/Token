pragma solidity 0.7.4;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/GSN/Context.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";
import "./IStakingMaster.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";


// Use the modified token vesting that forces the release function to be called by onlyOwner
import "../Vesting/VestingFactory.sol";
import "../Vesting/TokenVesting.sol";

// This contract contains a number of time-sensitive actions, it is widely known that time-sensitive actions can be manipulated by the miners reporting of time. This is not believed to be an issue within these contracts because it is dealing only with large time increments (weeks/months) and a miner can only influence the time reporting by ~15 seconds. It is accepted that time dependence events are allowed if they can vary by roughly 15 seconds and still maintain integrity.

contract StakingMaster is IStakingMaster, VestingFactory, Context, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 private auroxToken;

    address private providerAddress;

    // Store the static to prevent re-calculation's later on
    uint256 private secondsPerMonth = 2629746;

    // Keep track of the total invested amount
    uint256 public investedTotal = 0;

    uint256 private epochStart;

    mapping(address => Staking) public staking;

    mapping(address => address[]) private userInvestments;

    event NewStake(address stakeAddress);

    // If the user accidentally transfers ETH into the contract, revert the transfer
    fallback() external payable {
        revert();
    }

    constructor(address _auroxAddress, uint256 _epochStart) public {
        auroxToken = IERC20(_auroxAddress);
        epochStart = _epochStart;
    }

    // This function is required because the Provider contract needs access to the staking masters address in its constructor. So Staking Master must be deployed first, followed by the provider (with the staking master deployed address) and this function then sets the provider address.
    function setProviderAddress(address _providerAddress) external onlyOwner {
        require(
            _providerAddress != address(0),
            "The provider address has already been set"
        );
        providerAddress = _providerAddress;
    }

    // Function to return a given user's total stake value including all interest earnt up until the current point
    function returnUsersTotalStakeValue(address _user)
        public
        view
        override
        returns (uint256)
    {
        uint256 totalStakeValue;

        address[] memory usersStakes = userInvestments[_user];

        for (uint8 index = 0; index < usersStakes.length; index++) {
            uint256 currentStakeValue =
                returnCurrentStakeValue(usersStakes[index]);

            totalStakeValue = totalStakeValue.add(currentStakeValue);
        }

        return totalStakeValue;
    }

    // This function is intended to be called by the provider contract when the provider contract is adding rewards to a stake. It takes in a user's address as a parameter and returns a "valid" stake; a stake that is in progress and was created by the provider previously.
    function returnValidUsersProviderStake(address _user)
        public
        view
        override
        returns (address)
    {
        address[] memory usersStakes = userInvestments[_user];

        for (uint8 index = 0; index < usersStakes.length; index++) {
            address currentStake = usersStakes[index];
            if (
                staking[currentStake].providerStake == true &&
                staking[currentStake].stakeEndTime > block.timestamp
            ) {
                return usersStakes[index];
            }
        }
        // If no valid stakes found
        return address(0);
    }

    // Returns the interest percentage that a user is entitled to, based on the parameters
    function returnInterestPercentage(
        uint256 _duration,
        bool _epochOne,
        bool _fromStakingContract
    ) public view returns (uint256) {
        uint256 interestRate;
        uint256 maxInterestRate = uint256(20 ether).div(100);
        // Convert the duration into the proper base so the returned interest value has 18 decimals and 1e18 = 100%
        uint256 updatedDuration = _duration.mul(uint256(1 ether).div(100));
        
        // Calculate the initial interest rate as the months / 2
        interestRate = updatedDuration.div(2);

        // If the interest rate exceeds 20% set it to 20%
        if (interestRate > maxInterestRate) {
            interestRate = maxInterestRate;
        }

        if (_epochOne && _duration >= 12) {
            // If the amount is from epoch 1 then add 50% to the APY
            interestRate = interestRate.add(interestRate.div(2));
        } else if (_fromStakingContract) {
            // If the amount is from the liquidity contract then add 25% to the APY
            interestRate = interestRate.add(interestRate.div(4));
        }

        return interestRate;
    }

    // Return the simple interest based on the given parameters
    function returnSimpleInterest(
        uint256 _amount,
        uint256 _interest,
        uint256 _duration
    ) public view returns (uint256) {
        // Divide by 1 ether to remove the added decimals from multiplying the interest with 18 decimals by the amount with 18 decimals
        return
            _amount.add(
                _interest
                    .mul(_amount)
                    .div(1 ether)
                    .mul(_duration)
                    .div(secondsPerMonth)
                    .div(uint256(12))
            );
    }

    // Return the compound interest based on the given parameters
    function returnCompoundInterest(
        uint256 _amount,
        uint256 _interest,
        uint256 _duration
    ) public view returns (uint256) {
        // Store this constant divider value so it doesn't get recomputed each loop
        uint256 divider = uint256(1 ether).mul(uint256(12));
        // Calculate the compound interest over all complete months
        for (uint256 i = 0; i < _duration.div(secondsPerMonth); i++) {
            // Calculate the simple interest for the entire year then divide by 12 (The number of times compounding per year)
            _amount = _amount.add(_interest.mul(_amount).div(divider));
        }

        uint256 leftOverMonthSeconds = _duration.mod(secondsPerMonth);
        // Calculate the interest for the last left-over month
        if (leftOverMonthSeconds > 0) {
            // Calculates the interest for the left-over incomplete  month: interest * amount * (leftOverSeconds/secondsPerMonth) / 12
            _amount = _amount.add(
                _interest
                    .mul(_amount)
                    .div(1 ether)
                    .mul(leftOverMonthSeconds)
                    .div(secondsPerMonth)
                    .div(uint256(12))
            );
        }
        return _amount;
    }

    // Function to delegate the call to either a simple interest calculation or compound depending on the compounding parameter
    function returnTotalInterestAmount(
        uint256 _durationInSeconds,
        uint256 _interestRate,
        uint256 _amount,
        bool compounding
    ) public view returns (uint256) {
        if (compounding) {
            uint256 total =
                returnCompoundInterest(
                    _amount,
                    _interestRate,
                    _durationInSeconds
                );
            return total.sub(_amount);
        } else {
            uint256 total =
                returnSimpleInterest(
                    _amount,
                    _interestRate,
                    _durationInSeconds
                );
            return total.sub(_amount);
        }
    }

    // Create a stake for the user given the parameters
    function createStaking(
        uint256 _amount,
        uint256 _duration,
        address _recipient
    ) external override nonReentrant {
        require(_amount > 0, "Amount to create stake must be greater than 0");
        require(_duration > 0, "Duration must be longer than 0 months");
        require(_duration <= 84, "Duration must be less than or equal to 7 years");
        // Revert if duration > 7 years

        bool _fromProviderContract = false;

        // If the sender was the provider contract then give the interest rate boost
        if (_msgSender() == providerAddress) {
            _fromProviderContract = true;
        }


        // Do these checks here to prevent accidentally creating a Token Vesting contract that can't be funded
        if (_fromProviderContract == false) {
            // Although these checks are completed again with the transfer function, the vesting contract must be created before that transfer function is called. This ensures the vesting contract isn't accidentally created.
            require(
                auroxToken.allowance(_msgSender(), address(this)) >= _amount,
                "Allowance  of staking master not set to spend required amount"
            );
            // Require the user to have enough balance for the transfer amount
            require(
                auroxToken.balanceOf(_msgSender()) >= _amount,
                "The sender doesn't have enough balance to send the required amount"
            );
            
            
        } else {
            // Require the public funds to have enough balance for the paid out rewards
            require(
                auroxToken.balanceOf(address(auroxToken)) >= _amount,
                "The balance of the public funds is not large enough for the required amount"
            );
        }

        bool _epochOne = false;

        // If the current time is within the first epoch and the amount came from the staking master
        if (
            block.timestamp <= epochStart.add(14 days) && _fromProviderContract
        ) {
            _epochOne = true;
        }

        // The expected interest rate for the user
        uint256 interestRate =
            returnInterestPercentage(
                _duration,
                _epochOne,
                _fromProviderContract
            );

        bool compounding = true;

        // If the duration is less than 12 months then it is compounding
        if (_duration < 12) {
            compounding = false;
        }

        // The entire staking duration in seconds
        uint256 durationInSeconds = _duration.mul(secondsPerMonth);
        // The total earned interest on the stake
        uint256 interest =
            returnTotalInterestAmount(
                durationInSeconds,
                interestRate,
                _amount,
                compounding
            );

        if (_fromProviderContract == false) {
            // Do this in this manner so you don't need to check for math underflows
            // Add the interest amount to the public funds balance
            uint256 auroxBalance = auroxToken.balanceOf(address(auroxToken));

            require(auroxBalance >= 30000 ether, "Balance of Aurox Token must be greater than 30k");

            uint256 stakingPublicFundsBalance = auroxBalance.sub(30000 ether);
            // Require the balance to be greater than this amount
            require(
                stakingPublicFundsBalance >= interest,
                "Not enough Staking public funds balance to pay the interest"
            );
        } else {
            require(
                auroxToken.balanceOf(address(auroxToken)) >= interest,
                "Not enough balance in public funds to pay for interest"
            );
        }

        // Create the Vesting contract using the clone factory
        CloneTokenVesting vestingContract =
            createVestingContract(
                _recipient,
                block.timestamp.add(durationInSeconds),
                0,
                14 days,
                true
            );
        // Increase the overall invested total to include the additional amount + interest
        investedTotal = investedTotal.add(_amount.add(interest));

        // Transfer the user's investment amount into the vesting contract, or transfer it from the public funds it the creator is the provider contract
        if (_fromProviderContract) {
            auroxToken.safeTransferFrom(
                address(auroxToken),
                address(vestingContract),
                _amount.add(interest)
            );
        } else {
            auroxToken.safeTransferFrom(
                _msgSender(),
                address(vestingContract),
                _amount
            );
            // Transfer into the aurox token the amount
            auroxToken.safeTransferFrom(
                address(auroxToken),
                address(vestingContract),
                interest
            );
        }

        // Create the staking master struct to include the additional data
        staking[address(vestingContract)] = Staking(
            vestingContract,
            _amount,
            block.timestamp.add(durationInSeconds),
            interestRate,
            block.timestamp,
            compounding,
            _amount,
            block.timestamp,
            _fromProviderContract
        );
        // Add the created vesting contract to the user's investment mapping
        userInvestments[_recipient].push(address(vestingContract));
        // Emit event for creation if required
        emit NewStake(address(vestingContract));
    }

    function addToStake(address _stakingAddress, uint256 _amount)
        external
        override
        nonReentrant
    {
        require(
            _msgSender() == providerAddress,
            "Only the Provider contract can add to a stake"
        );
        require(
            staking[_stakingAddress].providerStake,
            "To add to a stake it must be a provider stake"
        );
        require(
            staking[_stakingAddress].stakeEndTime > block.timestamp,
            "Staking contract has finished"
        );
        // Calculate seconds left in the stake, so that the interest calculation isn't from the start of the stake and is from now
        uint256 secondsLeft =
            staking[_stakingAddress].stakeEndTime.sub(block.timestamp);

        // The expected interest for the additional amount
        uint256 interest =
            returnTotalInterestAmount(
                secondsLeft,
                staking[_stakingAddress].interestRate,
                _amount,
                staking[_stakingAddress].compounded
            );

        // The balance of the public funds must be enough for the interest amount
        require(
            auroxToken.balanceOf(address(auroxToken)) >= interest,
            "Not enough balance in public funds to pay for the additional interest amount"
        );

        // Transfer the added amount + the interest into the vesting contract from the public funds. This function is only ever called by the provider when claiming rewards, so the _amount should also come from public funds
        auroxToken.safeTransferFrom(
            address(auroxToken),
            address(staking[_stakingAddress].vestingContract),
            _amount.add(interest)
        );

        uint256 timeElapsedSinceLastUpdate =
            block.timestamp.sub(staking[_stakingAddress].lastUpdate);

        // Calculate the earned interest up to now.
        uint256 currentInterestAmount =
            returnTotalInterestAmount(
                timeElapsedSinceLastUpdate,
                staking[_stakingAddress].interestRate,
                staking[_stakingAddress].investedAmount,
                staking[_stakingAddress].compounded
            );

        // Add the new amount to the invested total + the expected interest on that additional amount
        investedTotal = investedTotal.add(_amount.add(interest));

        // Update the user's invested amount to include interest up to now + the new amount. This simplifies calculating interest later on.
        staking[_stakingAddress].investedAmount = staking[_stakingAddress]
            .investedAmount
            .add(_amount.add(currentInterestAmount));

        // Used to calculate the stake value later on
        staking[_stakingAddress].lastUpdate = block.timestamp;
        // Add the raw value to the amount
        staking[_stakingAddress].rawInvestedAmount = staking[_stakingAddress]
            .rawInvestedAmount
            .add(_amount);
    }

    function returnStakeState(address _stakingAddress)
        public
        view
        override
        returns (
            uint256 currentStakeValue,
            uint256 stakeEndTime,
            uint256 interestRate,
            uint256 lastUpdate,
            bool compounding,
            uint256 rawInvestedAmount,
            uint256 stakeStartTime
        )
    {
        Staking memory stake = staking[_stakingAddress];

        // Return the current stake value including interest up until this point
        uint256 stakesValue = returnCurrentStakeValue(_stakingAddress);
        return (
            stakesValue,
            stake.stakeEndTime,
            stake.interestRate,
            stake.lastUpdate,
            stake.compounded,
            stake.rawInvestedAmount,
            stake.stakeStartTime
        );
    }

    // Return all the user's created Staking Contracts
    function returnUsersStakes(address _user)
        public
        view
        override
        returns (address[] memory usersStakes)
    {
        return userInvestments[_user];
    }

    // The alternative to this loop is creating a mapping of indexes and an array of addresses. This allows fetching the stakes index directly without looping. But to enable that you must write and delete an additional time, this increases the gas cost more than this loop.
    function removeUsersStake(address stakeToRemove) private {
        address[] memory usersStakes = userInvestments[_msgSender()];
        uint8 index;
        // Interate over each stake to find the matching one
        for (uint256 i = 0; i < usersStakes.length; i++) {
            if (usersStakes[i] == stakeToRemove) {
                index = uint8(i);
                break;
            }
        }
        // If the stake is found update the array
        if (usersStakes.length > 1) {
            userInvestments[_msgSender()][index] = usersStakes[
                usersStakes.length - 1
            ];
        }
        // Remove last item
        userInvestments[_msgSender()].pop();
    }

    // Function to return the staked value including all generated interest up until the now
    function returnCurrentStakeValue(address _stakingAddress)
        public
        view
        override
        returns (uint256)
    {
        Staking memory stake = staking[_stakingAddress];
        uint256 timeElapsedSinceLastUpdate;

        // If the stake is complete
        if (stake.stakeEndTime < block.timestamp) {
            timeElapsedSinceLastUpdate = stake.stakeEndTime.sub(
                stake.lastUpdate
            );
        } else {
            timeElapsedSinceLastUpdate = block.timestamp.sub(stake.lastUpdate);
        }

        uint256 interest =
            returnTotalInterestAmount(
                timeElapsedSinceLastUpdate,
                stake.interestRate,
                stake.investedAmount,
                stake.compounded
            );

        return stake.investedAmount.add(interest);
    }

    function returnStakesClaimablePoolRewards(address _stakingAddress) public view override returns (uint256) {
        
        Staking memory stake = staking[_stakingAddress];

        // If the user has claimed pool rewards before, or if the stake contains no amounts return 0
        if (stake.investedAmount == 0) {
            return 0;
        }

        uint256 stakeTotalTime = stake.stakeEndTime.sub(
            stake.lastUpdate
        );

        uint256 interest =
            returnTotalInterestAmount(
                stakeTotalTime,
                stake.interestRate,
                stake.investedAmount,
                stake.compounded
            );

        uint256 stakeTotal = stake.investedAmount.add(interest);

        uint256 poolValue = auroxToken.balanceOf(address(this));

        // The user's share of the pool rewards
        uint256 poolRewardShare =
            poolValue.mul(stakeTotal).div(investedTotal);

        return poolRewardShare;
    }

    // This function returns a user's total claimable reward amount for any given time
    function returnStakesClaimableRewards(address _stakingAddress) public view override returns (uint256) {
        
        CloneTokenVesting vesting = CloneTokenVesting(_stakingAddress);
        // The available vested rewards
        uint256 claimableRewards = vesting._releasableAmount(auroxToken);

        return claimableRewards;
    }

    // Function to claim rewards for a user, it releases the funds from the Vesting contract and calculates the user's share of the pool rewards
    function claimRewards(address _stakingAddress) external override nonReentrant {
        CloneTokenVesting vesting = CloneTokenVesting(_stakingAddress);
        require(
            vesting.beneficiary() == _msgSender(),
            "Only the creator of the staking contract can claim rewards"
        );

        // This function also ensures that the vesting has started and the user can claim rewards
        vesting.release(auroxToken);

        // Get the user's staked total, to determine whether they can claim pool rewards
        uint256 stakeTotal = returnCurrentStakeValue(_stakingAddress);

        // If they have pool rewards to claim
        if (stakeTotal > 0) {
            // If no funds have been released from the Aurox Contract
            // Set the user's investedAmount to 0 so that they can't claim more pool rewards
            staking[_stakingAddress].investedAmount = 0;
            // Calculate the reward share from the pool
            uint256 poolValue = auroxToken.balanceOf(address(this));

            // // The user's share of the pool rewards
            uint256 poolRewardShare =
                poolValue.mul(stakeTotal).div(investedTotal);

            // As there is sometimes rounding issues when returning the stake total, set it to 0 to prevent a subtraction underflow
            if (investedTotal < stakeTotal) {
                investedTotal = 0;
            } else {
                // Update the investedTotal
                investedTotal = investedTotal.sub(stakeTotal);
            }

            // If pool rewards to claim
            if (poolRewardShare > 0) {
                // Because of the rounding issue with the invested total the pool reward share might slightly overflow the poolValue by a small amount, if so prevent the transaction failure
                if (poolRewardShare > poolValue) {
                    poolRewardShare = poolValue;
                }
                auroxToken.safeTransfer(_msgSender(), poolRewardShare);
            }
        }

        // If the user doesn't have additional rewards to claim from the vesting contract, delete it from the array and delete the struct
        if (auroxToken.balanceOf(_stakingAddress) == 0) {
            removeUsersStake(_stakingAddress);
            // Delete the struct item
            delete staking[_stakingAddress];
        }
    }

    // This function calculates how much the user is entitled to when a stake is closed early
    function returnClaimAmountForEarlyStakeClose(address _stakingAddress)
        public
        view
        returns (uint256)
    {
        Staking memory stake = staking[_stakingAddress];

        uint256 incompleteStakeTime = stake.stakeEndTime.sub(block.timestamp);

        uint256 stakeTotalTime = stake.stakeEndTime.sub(stake.stakeStartTime);

        uint256 penaltyTotal = stake.rawInvestedAmount.mul(incompleteStakeTime).div(stakeTotalTime).div(2);

        // Return the raw amount and subtract the penalty total
        return stake.rawInvestedAmount.sub(penaltyTotal);
    }

    // Close the staking contract with penalties
    function closeStake(address _stakingAddress) external override nonReentrant {
        // Require that the staking contract hasn't ended
        require(
            staking[_stakingAddress].stakeEndTime > block.timestamp,
            "Staking contract has finished"
        );

        CloneTokenVesting vesting = CloneTokenVesting(_stakingAddress);

        require(
            vesting.beneficiary() == _msgSender(),
            "Only the creator of the staking contract can close the staking contract"
        );
        // Require that the stake hasn't been revoked before
        require(
            vesting.revoked(address(auroxToken)) == false,
            "This vesting has already been revoked"
        );

        // Calculate the total duration that interest would have been generated for.
        uint256 totalDuration =
            staking[_stakingAddress].stakeEndTime.sub(
                staking[_stakingAddress].lastUpdate
            );

        // Calculate the total interest obtainable for the stake
        uint256 interest =
            returnTotalInterestAmount(
                totalDuration,
                staking[_stakingAddress].interestRate,
                staking[_stakingAddress].investedAmount,
                staking[_stakingAddress].compounded
            );

        // Add the interest amount to the invested amount
        uint256 stakeTotal =
            staking[_stakingAddress].investedAmount.add(interest);
        // As there is sometimes rounding issues when returning the stake total, set it to 0 to prevent a subtraction underflow
        if (investedTotal < stakeTotal) {
            investedTotal = 0;
        } else {
            // Update the investedTotal
            investedTotal = investedTotal.sub(stakeTotal);
        }

        // Revoke the vesting contract
        vesting.revoke(auroxToken);

        // Calculate what the user is owed
        uint256 claimAmount =
            returnClaimAmountForEarlyStakeClose(_stakingAddress);

        // Transfer the amount the user is owed
        auroxToken.safeTransfer(_msgSender(), claimAmount);

        removeUsersStake(_stakingAddress);
        // Delete the item from the array
        delete staking[_stakingAddress];
    }
}
