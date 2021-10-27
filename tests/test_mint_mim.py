import pytest
from brownie import Contract, ZERO_ADDRESS, Wei, chain

DUST_THRESHOLD = 10_000

def test_mint_mim(strategy, mim, gov, mim_whale, yvcrvseth_whale, yvcrvseth, vault, destination_vault):
    """ Strategy should receive yvusdc and mint MIM up to Collateral Ratio """
    vault_token = Contract(vault.token())

    initial_amount = 10_000*(10**yvcrvseth.decimals())
    CollateralRatio = 0.65
    # check that address has more than 100 yvusdc
    assert yvcrvseth.balanceOf(yvcrvseth_whale) > 100 * (10 ** yvcrvseth.decimals())

    vault_token.approve(vault, 2 ** 256 - 1, {"from":yvcrvseth_whale})
    assert destination_vault.totalAssets() == 0

    vault.deposit(initial_amount/(yvcrvseth.pricePerShare()/(10**yvcrvseth.decimals())), {'from': yvcrvseth_whale})

    assert mim.balanceOf(strategy) == 0

    chain.sleep(360)
    chain.mine(1)

    tx = strategy.harvest({"from": gov})

    total_gain = vault.strategies(strategy).dict()["totalGain"]
    total_loss = vault.strategies(strategy).dict()["totalLoss"]

    assert strategy.balanceOfWant() < DUST_THRESHOLD
    assert strategy.valueOfInvestment() > 0
    assert destination_vault.totalAssets() > 0

    chain.sleep(360)
    chain.mine(1)

    #produce gains
    mim.transfer(destination_vault, 100_000*(10**mim.decimals()), {"from": mim_whale})

    assert strategy.balanceOfWant() < DUST_THRESHOLD
    assert strategy.valueOfInvestment() > 0
    assert destination_vault.totalAssets() > 0

    chain.sleep(360 + 1)
    chain.mine(1)

    vault.revokeStrategy(strategy, {"from": gov})

    tx = strategy.harvest({"from": gov})

    assert False

    total_gain += tx.events["Harvested"]["profit"]
    total_loss += tx.events["Harvested"]["loss"]

    chain.sleep(360 + 1)
    chain.mine(1)

    assert vault.strategies(strategy).dict()["totalGain"] == total_gain
    assert vault.strategies(strategy).dict()["totalLoss"] == total_loss
    assert vault.strategies(strategy).dict()["totalDebt"] == 0
