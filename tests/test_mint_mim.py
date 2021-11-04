import pytest
from brownie import Contract, ZERO_ADDRESS, Wei, chain

DUST_THRESHOLD = 10_000
def info(strategy, mim, bb, steth, crvsteth, yvcrvsteth, destination_vault):
    print(f"Borrowed: {strategy.borrowedAmount()}")
    print(f"Collateral: {strategy.collateralAmount()}")
    print(f"Debt: {strategy.currentCRate()}")
    print(f"MIM: {mim.balanceOf(strategy)/1e18:_}")
    print(f"Want: {strategy.balanceOfWant()/1e18:_}")
    print(f"MIM in bb: {bb.balanceOf(mim, strategy)/1e18:_}")
    print(f"yvault shares: {destination_vault.balanceOf(strategy)/1e18:_}")
    print(f"MIM in Vault: {destination_vault.totalAssets()/1e18:_}")
    print(f"Want in bb: {bb.balanceOf(strategy.want(), strategy)/1e18:_}")
    print(f"STETH: {steth.balanceOf(strategy)/1e18:_}")
    print(f"crvSTETH: {crvsteth.balanceOf(strategy)/1e18:_}")
    print(f"yvcrvSTETH: {yvcrvsteth.balanceOf(strategy)/1e18:_}")

def test_mint_mim(strategy, mim, gov, mim_whale, yvcrvseth_whale, yvcrvseth, vault, destination_vault):
    """ Strategy should receive yvusdc and mint MIM up to Collateral Ratio """
    vault_token = Contract(vault.token())

    steth = Contract("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84")
    abracadabra = Contract("0x0BCa8ebcB26502b013493Bf8fE53aA2B1ED401C1")
    bb = Contract(abracadabra.bentoBox())
    print("beginning:")
    info(strategy, mim, bb, steth, vault_token, vault, destination_vault)

    initial_amount = 100*(10**yvcrvseth.decimals())
    CollateralRatio = 0.65
    # check that address has more than 100 yvusdc
    assert yvcrvseth.balanceOf(yvcrvseth_whale) > 100 * (10 ** yvcrvseth.decimals())

    vault_token.approve(vault, 2 ** 256 - 1, {"from":yvcrvseth_whale})
    assert destination_vault.totalAssets() == 0

    #bentoBox.deposit(want, address(this), address(this), _balanceOfWant, 0);
    #we need to add money to abra

    mim.approve(bb, 2**256-1, {"from":mim_whale})
    bb.deposit(mim, mim_whale, abracadabra, 1_000_000*(10**mim.decimals()), 0, {"from":mim_whale})
    vault.deposit(initial_amount/(yvcrvseth.pricePerShare()/(10**yvcrvseth.decimals())), {'from': yvcrvseth_whale})

    assert mim.balanceOf(strategy) == 0

    chain.sleep(360)
    chain.mine(1)

    print("first harvest:")
    tx = strategy.harvest({"from": gov})
    info(strategy, mim, bb, steth, vault_token, vault, destination_vault)
    print(tx.events['Harvested'])

    total_gain = vault.strategies(strategy).dict()["totalGain"]
    total_loss = vault.strategies(strategy).dict()["totalLoss"]

    assert strategy.balanceOfWant() < DUST_THRESHOLD
    assert strategy.valueOfInvestment() > 0
    assert destination_vault.totalAssets() > 0

    chain.sleep(360)
    chain.mine(1)

    #produce gains
    mim.transfer(destination_vault, 2_000*(10**mim.decimals()), {"from": mim_whale})

    print("after producing gains")
    info(strategy, mim, bb, steth, vault_token, vault, destination_vault)
    assert strategy.balanceOfWant() < DUST_THRESHOLD
    assert strategy.valueOfInvestment() > 0
    assert destination_vault.totalAssets() > 0

    chain.sleep(360 + 1)
    chain.mine(1)

    print("second harvest:")
    vault.revokeStrategy(strategy, {"from": gov})

    tx = strategy.harvest({"from": gov})
    info(strategy, mim, bb, steth, vault_token, vault, destination_vault)
    print(tx.events['Harvested'])

    total_gain += tx.events["Harvested"]["profit"]
    total_loss += tx.events["Harvested"]["loss"]

    chain.sleep(360 + 1)
    chain.mine(1)


    assert vault.strategies(strategy).dict()["totalGain"] == total_gain
    assert vault.strategies(strategy).dict()["totalLoss"] == total_loss
    assert vault.strategies(strategy).dict()["totalDebt"] == 0
