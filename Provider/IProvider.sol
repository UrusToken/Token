pragma solidity 0.7.4;

interface IProvider {
    /**
        @dev Returns the current user's investment total in the provider
        @param _user The user's address to return the total for
        @return The user's stake total
     */
    function returnUsersInvestmentTotal(address _user)
        external
        view
        returns (uint256);

    /**
        @dev The various investment values for a user based on a given epoch

        @param epoch The given epoch to return the values for
        @param _user The user to return totals for

        @return shareTotal The user's proportional share total based on when they invested into the epoch
        @return currentInvestmentTotal The user's raw investment total for the given epoch
        @return allPrevInvestmentTotals The sum of all amounts made into the Provider contract at the current epoch's time
     */
    function returnUsersEpochTotals(uint256 epoch, address _user)
        external
        view
        returns (
            uint256 shareTotal,
            uint256 currentInvestmentTotal,
            uint256 allPrevInvestmentTotals
        );

    /**
        @dev Returns the current APR of the Provider pool

        @return Returns the APR
     */
    function returnCurrentAPY() external view returns (uint256);

    /**
        @dev This function adds the liquidity to the provider contract and does all the work for the storage of epoch data, updating of totals, aggregating currentInvestmentTotal's and adding to the overall totals.

        @param _amount The amount of liquidity to add
     */
    function addLiquidity(uint256 _amount) external;

    /**
        @dev This function returns the available amount to claim for the given user.

        @param _user The address of the user to return the claimable amounts for
        @return rewardTotal The reward total to return
        @return lastLiquidityAddedEpochReference The last epoch where the user added liquidity
     */
    function returnAllClaimableRewardAmounts(address _user)
        external
        view
        returns (uint256 rewardTotal, uint256 lastLiquidityAddedEpochReference);

    /**
        @dev This functions claims all available rewards for the user, it looks through all epoch's since when they last claimed rewards and calculates the sum of their rewards to claim

        @param _sendRewardsToStaking Whether the rewards are to be sent into a staking contract
        @param stakeDuration The duration of the stake to be created
     */
    function claimRewards(bool _sendRewardsToStaking, uint256 stakeDuration)
        external;

    /**
        @dev This function removes the specified amount from the user's total and sends their tokens back to the user. The user will be penalised 10% if withdrawing outside of the first day in any givene poch

        @param _amount The amount to withdraw
     */
    function removeLiquidity(uint256 _amount) external;

    /**
        @dev Returns the current epoch to the user

        @return The current epoch
     */
    function returnCurrentEpoch() external view returns (uint256);
}
