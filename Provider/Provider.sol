pragma solidity 0.7.4;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/GSN/Context.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "../StakingMaster/IStakingMaster.sol";
import "./IProvider.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";


contract Provider is IProvider, Context, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 private epochStart;
    uint256 private epochLength = 14 days;

    address private owner;

    IERC20 private UniSwapToken;

    IERC20 private AuroxToken;

    IStakingMaster private StakingMasterContract;

    struct EpochInvestmentDetails {
        // Sum of all normalised epoch values
        uint256 shareTotal;
        // Sum of all liquidity amounts from the previous epochs
        uint256 allPrevInvestmentTotals;
        // Sum of all liquidity amounts, excluding amounts from the current epoch. This is so the share amounts aren't included twice.
        uint256 currentInvestmentTotal;
    }

    struct UserDetails {
        uint256 lastLiquidityAddedEpochReference;
        // A number representing when the user last updated the epoch amounts
        uint256 lastEpochUpdate;
        // A timestamp representing when the user last claimed rewards
        uint256 lastClaimedTimestamp;
        // A number representing the epoch that liquidity was last drawn from
        uint256 lastEpochLiquidityWithdrawn;
        // The mapping of epochs to investment details
        mapping(uint256 => EpochInvestmentDetails) epochTotals;
    }

    // For storing user details
    mapping(address => UserDetails) public userInvestments;

    // For storing overall details
    mapping(uint256 => EpochInvestmentDetails) public epochAmounts;

    uint256 public lastEpochUpdate = 1;

    // If the user accidentally transfers ETH into the contract, revert the transfer
    fallback() external payable {
        revert();
    }

    constructor(
        address _uniSwapTokenAddress,
        address _auroxTokenAddress,
        address _stakingMaster,
        uint256 _epochStart
    ) public {
        epochStart = _epochStart;
        UniSwapToken = IERC20(_uniSwapTokenAddress);
        AuroxToken = IERC20(_auroxTokenAddress);
        StakingMasterContract = IStakingMaster(_stakingMaster);
    }

    // Return the users total investment amount
    function returnUsersInvestmentTotal(address _user)
        public
        view
        override
        returns (uint256)
    {
        EpochInvestmentDetails memory latestInvestmentDetails =
            userInvestments[_user].epochTotals[
                userInvestments[_user].lastEpochUpdate
            ];
        // Return the users investment total based on the epoch they edited last
        uint256 investmentTotal =
            _returnEpochAmountIncludingCurrentTotal(latestInvestmentDetails);
        return (investmentTotal);
    }

    // Returns a user's epoch totals for a given epoch
    function returnUsersEpochTotals(uint256 epoch, address _user)
        public
        view
        override
        returns (
            uint256 shareTotal,
            uint256 currentInvestmentTotal,
            uint256 allPrevInvestmentTotals
        )
    {
        EpochInvestmentDetails memory investmentDetails =
            userInvestments[_user].epochTotals[epoch];
        return (
            investmentDetails.shareTotal,
            investmentDetails.currentInvestmentTotal,
            investmentDetails.allPrevInvestmentTotals
        );
    }

    function returnCurrentEpoch() public view override returns (uint256) {
        return block.timestamp.sub(epochStart).div(epochLength).add(1);
    }

    function _returnEpochToTimestamp(uint256 timestamp)
        public
        view
        returns (uint256)
    {
        // ((timestamp - epochStart) / epochLength) + 1;
        // Add 1 to the end because it will round down the remainder value
        return timestamp.sub(epochStart).div(epochLength).add(1);
    }

    function _getSecondsToEpochEnd(uint256 currentEpoch)
        public
        view
        returns (uint256)
    {
        // Add to the epoch start date the duration of the current epoch + 1 * the epoch length.
        // Then subtract the block.timestamp to get the duration to the next epoch
        // epochStart + (currentEpoch * epochLength) - block.timestamp
        uint256 epochEndTime = epochStart.add(currentEpoch.mul(epochLength));
        // Prevent a math underflow by returning 0 if the given epoch is complete
        if (epochEndTime < block.timestamp) {
            return 0;
        } else {
            return epochEndTime.sub(block.timestamp);
        }
    }

    // The actual epoch rewards are 750 per week. But that shouldn't affect this
    // If claiming from an epoch that is in-progress you would get a proportion anyway
    function returnTotalRewardForEpoch(uint256 epoch)
        public
        pure
        returns (uint256)
    {
        // If the epoch is greater than or equal to 10 return 600 as the reward. This prevents a safemath underflow
        if (epoch >= 10) {
            return 600 ether;
        }
        // 1500 - (epoch * 100)
        uint256 rewardTotal =
            uint256(1500 ether).sub(uint256(100 ether).mul(epoch.sub(1)));

        return rewardTotal;
    }

    function returnIfInFirstDayOfEpoch(uint256 currentEpoch)
        public
        view
        returns (bool)
    {
        uint256 secondsToEpochEnd = _getSecondsToEpochEnd(currentEpoch);
        // The subtraction overflows the the currentEpoch value passed in isn't the current epoch and a future epoch
        uint256 secondsToEpochStart = epochLength.sub(secondsToEpochEnd);

        // If the seconds to epoch start is less than 1 day then true
        if (secondsToEpochStart <= 1 days) {
            return true;
        } else {
            return false;
        }
    }

    // Function to calculate rewards over a year (26 epochs)
    function returnCurrentAPY() public view override returns (uint256) {
        uint256 currentEpoch = returnCurrentEpoch();
        uint256 totalReward;
        // Checks if there is epochs that have rewards that aren't equal to 600
        if (currentEpoch < 10) {
            // The amount of epochs where the rewards aren't equal to 600
            uint256 epochLoops = uint256(10).sub(currentEpoch);
            // Iterate over each epoch to grab rewards for each of those epochs
            for (
                uint256 i = currentEpoch;
                i < epochLoops.add(currentEpoch);
                i++
            ) {
                uint256 epochReward = returnTotalRewardForEpoch(i);
                totalReward = totalReward.add(epochReward);
            }
            // Add in $600 rewards for every epoch where the rewards are equal to 600
            totalReward = totalReward.add(
                uint256(600 ether).mul(uint256(26).sub(epochLoops))
            );
        } else {
            // Every epoch has rewards equal to $600
            totalReward = uint256(600 ether).mul(26);
        }

        // The overall total for all users
        uint256 overallEpochTotal =
            _returnEpochAmountIncludingCurrentTotal(
                epochAmounts[lastEpochUpdate]
            );

        // If 0 for the epoch total, set it to 1
        if (overallEpochTotal == 0) {
            overallEpochTotal = 1 ether;
        }
        uint256 totalAPY = totalReward.mul(1 ether).div(overallEpochTotal);

        return totalAPY;
    }

    function _updateUserDetailsAndEpochAmounts(
        address _userAddress,
        uint256 _amount
    ) internal {
        // Get the current epoch
        uint256 currentEpoch = _returnEpochToTimestamp(block.timestamp);
        uint256 secondsToEpochEnd = _getSecondsToEpochEnd(currentEpoch);

        UserDetails storage currentUser = userInvestments[_userAddress];

        if (currentUser.lastEpochUpdate == 0) {
            // Set the epoch for grabbing values to be this epoch.
            currentUser.lastLiquidityAddedEpochReference = currentEpoch;

            // Update when they last claimed to now, so they can't claim rewards for past epochs
            currentUser.lastClaimedTimestamp = block.timestamp;
        }

        uint256 usersTotal =
            _returnEpochAmountIncludingCurrentTotal(
                currentUser.epochTotals[currentUser.lastEpochUpdate]
            );
        // If they havent had an amount in the liquidity provider reset their boost reward, so they don't unexpectedly have a 100% boost reward immediately
        if (usersTotal == 0) {
            currentUser.lastEpochLiquidityWithdrawn = currentEpoch;

            // If they've claimed all rewards for their past investments, reset their last claimed timestamp to prevent them from looping uselessly
            uint256 lastClaimedEpoch =
                _returnEpochToTimestamp(currentUser.lastClaimedTimestamp);
            if (lastClaimedEpoch > currentUser.lastEpochUpdate) {
                currentUser.lastClaimedTimestamp = block.timestamp;
            }
        }

        // Normalise the epoch share as amount * secondsToEpochEnd / epochlength;
        uint256 epochShare = _amount.mul(secondsToEpochEnd).div(epochLength);

        // If the user hasn't added to the current epoch, carry over their investment total into the current epoch totals and update the reference for grabbing up to date user totals
        if (currentUser.lastEpochUpdate < currentEpoch) {
            // The pulled forward user's total investment amount
            uint256 allPrevInvestmentTotals =
                currentUser.epochTotals[currentUser.lastEpochUpdate]
                    .allPrevInvestmentTotals;

            // Add the allPrevInvestmentTotals to the currentInvestmentTotal to reflect the new overall investment total
            uint256 pulledForwardTotal =
                allPrevInvestmentTotals.add(
                    currentUser.epochTotals[currentUser.lastEpochUpdate]
                        .currentInvestmentTotal
                );

            // Update the investment total by pulling forward the total amount from when the user last added liquidity
            currentUser.epochTotals[currentEpoch]
                .allPrevInvestmentTotals = pulledForwardTotal;

            // Update when liquidity was added last
            currentUser.lastEpochUpdate = currentEpoch;
        }

        // Update the share total for the current epoch

        currentUser.epochTotals[currentEpoch].shareTotal = currentUser
            .epochTotals[currentEpoch]
            .shareTotal
            .add(epochShare);

        // Update the user's currentInvestmentTotal to include the added amount
        currentUser.epochTotals[currentEpoch]
            .currentInvestmentTotal = currentUser.epochTotals[currentEpoch]
            .currentInvestmentTotal
            .add(_amount);

        /* Do the same calculations but add it to the overall totals not the users */

        // If the investment total hasn't been carried over into the "new" epoch
        if (lastEpochUpdate < currentEpoch) {
            // The pulled forward everyone's total amount
            uint256 allPrevInvestmentTotals =
                epochAmounts[lastEpochUpdate].allPrevInvestmentTotals;

            // The total pulled forward amount, including investments made on that epoch.
            uint256 overallPulledForwardTotal =
                allPrevInvestmentTotals.add(
                    epochAmounts[lastEpochUpdate].currentInvestmentTotal
                );

            // Update the current epoch investment total to have the pulled forward totals from all other epochs.
            epochAmounts[currentEpoch]
                .allPrevInvestmentTotals = overallPulledForwardTotal;

            // Update the lastEpochUpdate value
            lastEpochUpdate = currentEpoch;
        }

        // Update the share total for everyone to include the additional amount
        epochAmounts[currentEpoch].shareTotal = epochAmounts[currentEpoch]
            .shareTotal
            .add(epochShare);

        // Update the current investment total for everyone
        epochAmounts[currentEpoch].currentInvestmentTotal = epochAmounts[
            currentEpoch
        ]
            .currentInvestmentTotal
            .add(_amount);
    }

    function addLiquidity(uint256 _amount) external override nonReentrant {
        require(block.timestamp > epochStart, "Epoch one hasn't started yet");
        require(_amount != 0, "Cannot add a 0 amount");

        require(
            UniSwapToken.allowance(_msgSender(), address(this)) >= _amount,
            "Allowance of Provider not large enough for the required amount"
        );
        // Require the user to have enough balance for the transfer amount
        require(
            UniSwapToken.balanceOf(_msgSender()) >= _amount,
            "Balance of the sender not large enough for the required amount"
        );

        UniSwapToken.safeTransferFrom(_msgSender(), address(this), _amount);

        _updateUserDetailsAndEpochAmounts(_msgSender(), _amount);
    }

    function returnGivenEpochEndTime(uint256 epoch)
        public
        view
        returns (uint256)
    {
        return epochStart.add(epochLength.mul(epoch));
    }

    function returnGivenEpochStartTime(uint256 epoch)
        public
        view
        returns (uint256)
    {
        return epochStart.add(epochLength.mul(epoch.sub(1)));
    }

    // Returns the seconds that a user can claim rewards for in any given epoch
    function _returnEpochClaimSeconds(
        uint256 epoch,
        uint256 currentEpoch,
        uint256 lastEpochClaimed,
        uint256 lastClaimedTimestamp
    ) public view returns (uint256) {
        // If the given epoch is the current epoch
        if (epoch == currentEpoch) {
            // If the user claimed rewards in this epoch, the claim seconds would be the block.timestamp - lastClaimedtimestamp
            if (lastEpochClaimed == currentEpoch) {
                return block.timestamp.sub(lastClaimedTimestamp);
            }
            // If the user hasn't claimed in this epoch, the claim seconds is the timestamp - startOfEpoch
            uint256 givenEpochStartTime = returnGivenEpochStartTime(epoch);

            return block.timestamp.sub(givenEpochStartTime);
            // If the user last claimed in the given epoch, but it isn't the current epoch
        } else if (lastEpochClaimed == epoch) {
            // The claim seconds is the end of the given epoch - the lastClaimed timestmap
            uint256 givenEpochEndTime = returnGivenEpochEndTime(epoch);
            // If they've already claimed rewards in this epoch, calculate their claim seconds as the difference between that timestamp and now.

            return givenEpochEndTime.sub(lastClaimedTimestamp);
        }

        // Return full length of epoch if it isn't the current epoch and the user hasn't previously claimed in this epoch.
        return epochLength;
    }

    function _returnEpochAmountIncludingShare(
        EpochInvestmentDetails memory epochInvestmentDetails
    ) internal pure returns (uint256) {
        return
            epochInvestmentDetails.allPrevInvestmentTotals.add(
                epochInvestmentDetails.shareTotal
            );
    }

    function _returnEpochAmountIncludingCurrentTotal(
        EpochInvestmentDetails memory epochInvestmentDetails
    ) internal view returns (uint256) {
        return
            epochInvestmentDetails.allPrevInvestmentTotals.add(
                epochInvestmentDetails.currentInvestmentTotal
            );
    }

    function _returnRewardAmount(
        uint256 usersInvestmentTotal,
        uint256 overallInvestmentTotal,
        uint256 secondsToClaim,
        uint256 totalReward
    ) public view returns (uint256) {
        // Calculate the total epoch reward share as: totalReward * usersInvestmentTotal / overallEpochTotal
        uint256 totalEpochRewardShare =
            totalReward.mul(usersInvestmentTotal).div(overallInvestmentTotal);

        // Calculate the proportional reward share as totalEpochRewardShare * secondsToClaim / epochLength
        uint256 proportionalRewardShare =
            totalEpochRewardShare.mul(secondsToClaim).div(epochLength);
        // totalReward * (usersInvestmentTotal / overallEpochTotal) * (secondsToClaim / epochLength)

        return proportionalRewardShare;
    }

    function _calculateRewardShareForEpoch(
        uint256 epoch,
        uint256 currentEpoch,
        uint256 lastEpochClaimed,
        uint256 lastClaimedTimestamp,
        uint256 usersInvestmentTotal,
        uint256 overallInvestmentTotal
    ) internal view returns (uint256) {
        // If the last claimed timestamp is the same epoch as the epoch passed in
        uint256 claimSeconds =
            _returnEpochClaimSeconds(
                epoch,
                currentEpoch,
                lastEpochClaimed,
                lastClaimedTimestamp
            );

        // Total rewards in the given epoch
        uint256 totalEpochRewards = returnTotalRewardForEpoch(epoch);

        return
            _returnRewardAmount(
                usersInvestmentTotal,
                overallInvestmentTotal,
                claimSeconds,
                totalEpochRewards
            );
    }

    function returnAllClaimableRewardAmounts(address _user)
        public
        view
        override
        returns (uint256 rewardTotal, uint256 lastLiquidityAddedEpochReference)
    {
        UserDetails storage currentUser = userInvestments[_user];

        // If the user has no investments return 0
        if (currentUser.lastEpochUpdate == 0) {
            return (0,0);
        }

        uint256 currentEpoch = _returnEpochToTimestamp(block.timestamp);

        uint256 rewardTotal;

        // The last epoch they claimed from, to seed the start of the for-loop
        uint256 lastEpochClaimed =
            _returnEpochToTimestamp(currentUser.lastClaimedTimestamp);

        // To hold the users total in a given epoch
        uint256 usersEpochTotal;

        // To hold the overall total in a given epoch
        uint256 overallEpochTotal;

        // Reference to grab the user's latest epoch totals
        uint256 lastLiquidityAddedEpochReference =
            currentUser.lastLiquidityAddedEpochReference;

        // Reference to grab the overall epoch totals
        uint256 overallLastLiquidityAddedEpochReference =
            lastLiquidityAddedEpochReference;

        for (uint256 epoch = lastEpochClaimed; epoch <= currentEpoch; epoch++) {
            // If the user did invest in this epoch, then their total investment amount is allTotals + shareAmount
            if (currentUser.epochTotals[epoch].shareTotal != 0) {
                // Update the reference for where to find values
                if (lastLiquidityAddedEpochReference != epoch) {
                    lastLiquidityAddedEpochReference = epoch;
                }
                // Update the user's total to include the share amount, as they invested in this epoch
                usersEpochTotal = _returnEpochAmountIncludingShare(
                    currentUser.epochTotals[epoch]
                );
            } else {
                // Prevent this statement executing multiple times by only executing it after the epoch reference is updated or if the value hasn't been set yet
                if (
                    epoch == lastLiquidityAddedEpochReference.add(1) ||
                    usersEpochTotal == 0
                ) {
                    usersEpochTotal = _returnEpochAmountIncludingCurrentTotal(
                        currentUser.epochTotals[
                            lastLiquidityAddedEpochReference
                        ]
                    );
                }
            }

            // If no rewards to be claimed for the current epoch, skip this loop
            if (usersEpochTotal == 0) continue;

            // If any user added amounts during this epoch, then update the overall total to include their share totals
            if (epochAmounts[epoch].shareTotal != 0) {
                // Update the reference of where to find an epoch total
                if (overallLastLiquidityAddedEpochReference != epoch) {
                    overallLastLiquidityAddedEpochReference = epoch;
                }
                // Set the overall epoch total to include the share
                overallEpochTotal = _returnEpochAmountIncludingShare(
                    epochAmounts[epoch]
                );
            } else {
                // Prevent this statement executing multiple times by only executing it after the epoch reference is updated or if the value hasn't been set yet
                if (
                    epoch == overallLastLiquidityAddedEpochReference.add(1) ||
                    overallEpochTotal == 0
                ) {
                    overallEpochTotal = _returnEpochAmountIncludingCurrentTotal(
                        epochAmounts[lastLiquidityAddedEpochReference]
                    );
                }
            }

            // Calculate the reward share for the epoch
            uint256 epochRewardShare =
                _calculateRewardShareForEpoch(
                    epoch,
                    currentEpoch,
                    lastEpochClaimed,
                    currentUser.lastClaimedTimestamp,
                    usersEpochTotal,
                    overallEpochTotal
                );

            rewardTotal = rewardTotal.add(epochRewardShare);
        }

        uint256 epochsCompleteWithoutWithdrawal =
            currentEpoch.sub(currentUser.lastEpochLiquidityWithdrawn);

        if (epochsCompleteWithoutWithdrawal > 10) {
            epochsCompleteWithoutWithdrawal = 10;
        }

        if (epochsCompleteWithoutWithdrawal != 0) {
            rewardTotal = rewardTotal.add(
                rewardTotal.mul(epochsCompleteWithoutWithdrawal).div(10)
            );
        }

        return (rewardTotal, lastLiquidityAddedEpochReference);
    }

    function claimRewards(bool _sendRewardsToStaking, uint256 stakeDuration)
        public
        override
        nonReentrant
    {
        UserDetails storage currentUser = userInvestments[_msgSender()];

        // require the user to actually have an investment amount
        require(
            currentUser.lastEpochUpdate > 0,
            "User has no rewards to claim, as they have never added liquidity"
        );

        (
            uint256 allClaimableAmounts,
            uint256 lastLiquidityAddedEpochReference
        ) = returnAllClaimableRewardAmounts(_msgSender());

        currentUser
            .lastLiquidityAddedEpochReference = lastLiquidityAddedEpochReference;

        // Update their last claim to now
        currentUser.lastClaimedTimestamp = block.timestamp;

        // Return if no rewards to claim. Don't revert otherwise the user's details won't update to now and they will continually loop over epoch's that contain no rewards.
        if (allClaimableAmounts == 0) {
            return;
        }

        if (_sendRewardsToStaking) {
            // Return a valid stake for the user
            address usersStake =
                StakingMasterContract.returnValidUsersProviderStake(
                    _msgSender()
                );

            // If the stake is valid add the amount to it
            if (usersStake != address(0)) {
                StakingMasterContract.addToStake(
                    usersStake,
                    allClaimableAmounts
                );
                // Otherwise create a new stake for the user
            } else {
                StakingMasterContract.createStaking(
                    allClaimableAmounts,
                    stakeDuration,
                    _msgSender()
                );
            }
            // If not sending the rewards to staking simply sends the rewards back to the user
        } else {
            AuroxToken.safeTransferFrom(
                address(AuroxToken),
                _msgSender(),
                allClaimableAmounts
            );
        }
    }

    function _returnClaimSecondsForPulledLiquidity(
        uint256 lastClaimedTimestamp,
        uint256 currentEpoch
    ) public view returns (uint256) {
        uint256 lastClaimedEpoch =
            _returnEpochToTimestamp(lastClaimedTimestamp);

        uint256 claimSecondsForPulledLiquidity;

        if (lastClaimedEpoch == currentEpoch) {
            // If they've claimed in this epoch, they should only be able to claim from when they last claimed to now
            return
                claimSecondsForPulledLiquidity = block.timestamp.sub(
                    lastClaimedTimestamp
                );
        } else {
            // If they haven't claimed in this epoch, then the claim seconds are from when the epoch start to now
            uint256 secondsToEpochEnd = _getSecondsToEpochEnd(currentEpoch);

            return epochLength.sub(secondsToEpochEnd);
        }
    }

    function removeLiquidity(uint256 _amount) public override nonReentrant {
        UserDetails storage currentUser = userInvestments[_msgSender()];

        // The epoch the user last added liquidity, this will give the latest version of their total amounts


            EpochInvestmentDetails
                storage usersLastAddedLiquidityEpochInvestmentDetails
         = currentUser.epochTotals[currentUser.lastEpochUpdate];

        // Calculate the user's total based on when they last added liquidity

        uint256 usersTotal =
            _returnEpochAmountIncludingCurrentTotal(
                usersLastAddedLiquidityEpochInvestmentDetails
            );

        // Ensure the user has enough amount to deduct the balance
        require(
            usersTotal >= _amount,
            "User doesn't have enough balance to withdraw the amount"
        );

        uint256 currentEpoch = _returnEpochToTimestamp(block.timestamp);

        // The users investment details for the current epoch
        EpochInvestmentDetails storage usersCurrentEpochInvestmentDetails =
            currentUser.epochTotals[currentEpoch];

        /* Calculate how much to remove from the user's share total if they have invested in the same epoch they are removing from */

        // How many seconds they can claim from the current epoch
        uint256 claimSecondsForPulledLiquidity =
            _returnClaimSecondsForPulledLiquidity(
                currentUser.lastClaimedTimestamp,
                currentEpoch
            );

        // How much the _amount is claimable since epoch start or when they last claimed rewards
        uint256 claimAmountOnPulledLiquidity =
            _amount.mul(claimSecondsForPulledLiquidity).div(epochLength);

        // In the very rare case that they have no claim to the pulled liquidity, set the value to 1. This negates issues in the claim rewards function
        if (claimAmountOnPulledLiquidity == 0) {
            claimAmountOnPulledLiquidity = 1;
        }

        // If they have a share total in this epoch, then deduct it from the overall total and add the new calculated share total
        if (usersCurrentEpochInvestmentDetails.shareTotal != 0) {
            epochAmounts[currentEpoch].shareTotal = epochAmounts[currentEpoch]
                .shareTotal
                .sub(usersCurrentEpochInvestmentDetails.shareTotal);
        }

        // NOTE: They lose the reward amount they've earnt on a share total. If they add liqudiity and pull in same epoch they lose rewards earnt on the share total.
        usersCurrentEpochInvestmentDetails
            .shareTotal = claimAmountOnPulledLiquidity;

        // If they haven't updated in this epoch. Pull the total forward minus the amount
        if (currentUser.lastEpochUpdate != currentEpoch) {
            // Update the overall total to refelct the updated amount
            usersCurrentEpochInvestmentDetails
                .allPrevInvestmentTotals = usersTotal.sub(_amount);

            // Update when it was last updated
            currentUser.lastEpochUpdate = currentEpoch;
        } else {
            // If there isn't enough in the allPrevInvestmentTotal for the subtracted amount
            if (
                usersLastAddedLiquidityEpochInvestmentDetails
                    .allPrevInvestmentTotals < _amount
            ) {
                // Update the amount so it deducts the allPrevAmount
                uint256 usersRemainingAmount =
                    _amount.sub(
                        usersLastAddedLiquidityEpochInvestmentDetails
                            .allPrevInvestmentTotals
                    );

                // Set the prev investment total to 0
                usersCurrentEpochInvestmentDetails.allPrevInvestmentTotals = 0;

                // Deduct from the currentInvestmentTotal the remaining _amount
                usersCurrentEpochInvestmentDetails
                    .currentInvestmentTotal = usersLastAddedLiquidityEpochInvestmentDetails
                    .currentInvestmentTotal
                    .sub(usersRemainingAmount);
            } else {
                // Subtract from their allPrevInvestmentTotal the amount to deduct and then update the user's total on the current epoch to be the new amounts
                usersCurrentEpochInvestmentDetails
                    .allPrevInvestmentTotals = usersLastAddedLiquidityEpochInvestmentDetails
                    .allPrevInvestmentTotals
                    .sub(_amount);

                // Pull forward the current investment total
                usersCurrentEpochInvestmentDetails
                    .currentInvestmentTotal = usersLastAddedLiquidityEpochInvestmentDetails
                    .currentInvestmentTotal;
            }
        }

        // Update when the user last withdrew liquidity
        currentUser.lastEpochLiquidityWithdrawn = currentEpoch;

        // Update the share total
        epochAmounts[currentEpoch].shareTotal = epochAmounts[currentEpoch]
            .shareTotal
            .add(claimAmountOnPulledLiquidity);
        // If the epoch amounts for this epoch haven't been updated
        if (lastEpochUpdate != currentEpoch) {
            uint256 overallEpochTotal =
                _returnEpochAmountIncludingCurrentTotal(
                    epochAmounts[lastEpochUpdate]
                );

            // Update the overall total to refelct the updated amount
            epochAmounts[currentEpoch]
                .allPrevInvestmentTotals = overallEpochTotal.sub(_amount);

            // Update when it was last updated
            lastEpochUpdate = currentEpoch;
        } else {
            // If there isnt enough in the total investment totals for the amount
            if (epochAmounts[currentEpoch].allPrevInvestmentTotals < _amount) {
                // Update the amount so it deducts the allPrevAmount
                uint256 overallRemainingAmount =
                    _amount.sub(
                        epochAmounts[currentEpoch].allPrevInvestmentTotals
                    );

                // Set the prev investment total to 0
                epochAmounts[currentEpoch].allPrevInvestmentTotals = 0;

                // Deduct from the currentInvestmentTotal the remaining _amount
                epochAmounts[currentEpoch]
                    .currentInvestmentTotal = epochAmounts[currentEpoch]
                    .currentInvestmentTotal
                    .sub(overallRemainingAmount);
            } else {
                // Subtract from their allPrevInvestmentTotal the amount to deduct and then update the user's total on the current epoch to be the new amounts
                epochAmounts[currentEpoch]
                    .allPrevInvestmentTotals = epochAmounts[currentEpoch]
                    .allPrevInvestmentTotals
                    .sub(_amount);

                // Pull forward the current investment total
                epochAmounts[currentEpoch]
                    .currentInvestmentTotal = epochAmounts[currentEpoch]
                    .currentInvestmentTotal;
            }
        }

        // If the user is withdrawing in the first day of the epoch, then they get penalised no rewards
        if (returnIfInFirstDayOfEpoch(currentEpoch)) {
            UniSwapToken.safeTransfer(_msgSender(), _amount);
        } else {
            // Transfer 90% of the _amount to the user
            UniSwapToken.safeTransfer(_msgSender(), _amount.mul(9).div(10));
            // Transfer 10% to the burn address
            UniSwapToken.safeTransfer(
                0x0000000000000000000000000000000000000001,
                _amount.div(10)
            );
        }
    }
}
