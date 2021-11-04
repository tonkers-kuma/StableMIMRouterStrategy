import pytest
from brownie import chain, Wei, reverts, Contract
from eth_abi import encode_single


def test_prepare_migration(strategy, mim, gov, mim_whale, yvcrvsteth_whale, yvcrvsteth, vault, destination_vault, strategist, rewards, keeper, abracadabra):

    clone_tx = strategy.cloneMIMMinter(
        vault, strategist, rewards, keeper, destination_vault, abracadabra, 75_000, 60_000, "ClonedStrategy"
    )

    cloned_strategy = Contract.from_abi(
        "Strategy", clone_tx.events["FullCloned"]["clone"], strategy.abi
    )

    vault_token = Contract(vault.token())
    bb = Contract(abracadabra.bentoBox())

    initial_amount = 100*(10**yvcrvsteth.decimals())

    # check that address has more than 100 yvusdc
    assert yvcrvsteth.balanceOf(yvcrvsteth_whale) > 100 * (10 ** yvcrvsteth.decimals())

    vault_token.approve(vault, 2 ** 256 - 1, {"from":yvcrvsteth_whale})
    assert destination_vault.totalAssets() == 0

    #we need to add money to abra
    mim.approve(bb, 2**256-1, {"from":mim_whale})
    bb.deposit(mim, mim_whale, abracadabra, 1_000_000*(10**mim.decimals()), 0, {"from":mim_whale})
    vault.deposit(initial_amount/(yvcrvsteth.pricePerShare()/(10**yvcrvsteth.decimals())), {'from': yvcrvsteth_whale})

    chain.sleep(360)
    chain.mine(1)

    tx = strategy.harvest({"from": gov})

    assert mim.balanceOf(strategy) == 0
    assert destination_vault.balanceOf(strategy) > 0
    assert strategy.balanceOfWant() == 0
    assert strategy.estimatedTotalAssets() > 0

    prev_mim = mim.balanceOf(strategy)
    prev_mim_vault = destination_vault.balanceOf(strategy)
    prev_yvcrvsteth = yvcrvsteth.balanceOf(strategy)
    prev_estimated_assets = strategy.estimatedTotalAssets()
    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    vault.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})

    strategy.migrate(cloned_strategy, {"from": vault})

    assert mim.balanceOf(strategy) == 0
    assert destination_vault.balanceOf(strategy) == 0
    assert yvcrvsteth.balanceOf(strategy) == 0
    assert strategy.estimatedTotalAssets() == 0

    assert mim.balanceOf(cloned_strategy) == prev_mim
    assert destination_vault.balanceOf(cloned_strategy) == prev_mim_vault
    assert yvcrvsteth.balanceOf(cloned_strategy) == prev_yvcrvsteth
    assert cloned_strategy.estimatedTotalAssets() == prev_estimated_assets
