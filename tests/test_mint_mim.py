import pytest
from brownie import Contract, ZERO_ADDRESS, Wei, chain

DUST_THRESHOLD = 10_000

def test_mint_mim(strategy, mim, gov, mim_whale, yvusdc_whale, vault, destination_vault):
    """ Strategy should receive yvusdc and mint MIM up to Collateral Ratio """
    yvusdc = Contract(strategy.want())
    vault_token = Contract(vault.token())

    CollateralRatio = 0.90
    # check that address has more than 100 yvusdc
    assert yvusdc.balanceOf(yvusdc_whale) > 100 * (10 ** yvusdc.decimals())

    vault_token.approve(vault, 2 ** 256 - 1, {"from":yvusdc_whale})

    assert False
    vault.deposit(100_000/(yvusdc.pricePerShare()/(10**yvusdc.decimals())), {'from': yvusdc_whale})

    assert mim.balanceOf(strategy) == 0

    chain.sleep(360)
    chain.mine(1)

    amount = vault.balanceOf(yvusdc_whale) * vault.pricePerShare() / (10**yvusdc.decimals())
    strategy.harvest({"from": gov})

    resultingMIM = amount * yvusdc.pricePerShare() / (10**yvusdc.decimals()) * CollateralRatio

    assert strategy.balanceOfWant() < DUST_THRESHOLD
    assert strategy.valueOfInvestment() > 0
    assert abs(100_000*(10**yvusdc.decimals())*CollateralRatio - resultingMIM) < DUST_THRESHOLD
