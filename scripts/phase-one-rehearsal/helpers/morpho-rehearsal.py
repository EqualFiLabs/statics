"""Separate later-activation Cast experiment with pinned upstream Morpho code."""
import json
import os
from pathlib import Path
import subprocess
from phase_two_runtime import MAX, ZERO, command, data, keccak
from execution_evidence import require, save, validate_cases

MARKET = '(address,address,address,address,uint256)'
MANDATORY = {
    'later-morpho-cut', 'morpho-configuration', 'morpho-tracked-deposit', 'morpho-borrow',
    'morpho-unhealthy-liquidation', 'morpho-direct-topup', 'morpho-topup-sync',
    'morpho-exit-only', 'morpho-exit-deploy-blocked', 'morpho-exit-borrow-blocked', 'morpho-exit-repay',
    'morpho-healthy-liquidation', 'morpho-unsafe-surplus', 'morpho-surplus-withdrawal',
    'morpho-recall', 'morpho-final-liquidation', 'morpho-loss-sync', 'morpho-liquidator-redemption',
}


def exercise(run):
    repo, root = run.repo, run.root
    upstream = Path(os.environ['STATICS_REHEARSAL_ARTIFACT_ROOT']) / 'upstream/out/UpstreamMorphoCompilation.sol/UpstreamMorphoCompilation.json'
    require(upstream.is_file(), 'compile pinned upstream Morpho with Paris before later activation')
    env = {**os.environ, 'PRIVATE_KEY': command('cast', 'wallet', 'private-key',
           'test test test test test test test test test test test junk', '0'),
           'STATICS_UPSTREAM_MORPHO_ARTIFACT': str(upstream),
           'STATICS_REHEARSAL_MORPHO_OWNER': run.executor,
           'STATICS_REHEARSAL_MORPHO_CANDIDATE': str(root / 'morpho-candidate.json')}
    with (root / 'deployment.log').open('w') as log:
        subprocess.run(['forge', 'script', 'script/DeployMorphoRehearsal.s.sol:DeployMorphoRehearsal',
            '--rpc-url', run.url, '--broadcast', '--slow', '--legacy', '--disable-code-size-limit',
            '--out', os.environ['PHASE_TWO_OUT'], '--cache-path', str(Path(os.environ['PHASE_TWO_OUT']).parent/'cache')],
            cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    deployed = json.loads((root/'morpho-candidate.json').read_text())
    morpho, oracle = deployed['morpho'], deployed['oracle']
    artifact = json.loads(upstream.read_text())
    from importlib.util import module_from_spec, spec_from_file_location
    spec = spec_from_file_location('release', repo / 'scripts/public-hooks/release.py')
    release = module_from_spec(spec)
    spec.loader.exec_module(release)
    release.check_runtime(artifact, bytes.fromhex(run.code(morpho)[2:]))
    require(artifact['metadata']['compiler']['version'].startswith('0.8.19+commit.7dd6d404')
            and artifact['metadata']['settings']['evmVersion'] == 'paris', 'upstream build drift')
    cut = deployed['cut']
    run.safe('later-morpho-cut', [run.diamond], [cut], case_target=run.diamond, case_data=cut)
    run.send(None, morpho, data('enableIrm(address)', ZERO), sender=run.executor)
    run.send(None, morpho, data('enableLltv(uint256)', 77*10**16), sender=run.executor)
    market = (run.weth, run.token, oracle, ZERO, 77*10**16)
    encoded = command('cast','abi-encode','f('+MARKET+')', '('+','.join(map(str,market))+')')
    market_id = '0x'+keccak(bytes.fromhex(encoded[2:])).hex()
    run.send(None,morpho,data('createMarket('+MARKET+')',market))
    config = [data('initializeMorphoIntegration(address,address,uint16)',morpho,run.weth,0),
              data('setBasketDistributor(address,bool)',morpho,True),
              data('registerMorphoMarket('+MARKET+',uint8,uint256,uint8)',market,1,run.basket_id,1)]
    run.safe('morpho-configuration',[run.diamond]*3,config,case_target=run.diamond,case_data=config[1])
    require(run.scalar(run.diamond,'isBasketDistributor(address)(bool)',morpho), 'Morpho approval missing after batch')
    run.send(None,run.weth,data('deposit()'),sender=run.executor,value=1000*10**18)
    run.approve(run.weth,morpho,sender=run.executor)
    run.send(None,morpho,data('supply('+MARKET+',uint256,uint256,address,bytes)',market,1000*10**18,0,run.executor,'0x'),sender=run.executor)
    quote=run.scalar(run.diamond,'quoteMint(uint256,uint256)(uint256[])',run.basket_id,200*10**18)
    run.send(None,run.diamond,data('mint(uint256,uint256,address,uint256[])',run.basket_id,200*10**18,run.alice,quote))
    run.approve(run.token,run.diamond)
    position=int(run.scalar(run.diamond,'nextPositionId()(uint256)'))
    run.send(None,run.diamond,data('createAndDepositBasketCollateral(uint256,uint256,address)',run.basket_id,100*10**18,run.alice),
             value=int(run.scalar(run.diamond,'positionCreationFee()(uint256)')))
    run.positions.append(position)
    run.send('morpho-tracked-deposit',run.diamond,data('deployMorphoCollateral(uint256,bytes32,uint256)',position,market_id,80*10**18))
    run.send('morpho-borrow',run.diamond,data('borrowMorphoUsd(uint256,bytes32,uint256,uint256,address)',position,market_id,50*10**18,MAX,run.alice))
    run.morpho_context=dict(address=morpho,position=position,market=market_id)
    account=run.scalar(run.diamond,'morphoAccount(uint256)(address,bool)',position)
    run.approve(run.weth,morpho)
    require(int(run.scalar(run.token,'balanceOf(address)(uint256)',run.liquidator)) == 0,
            'liquidator already owns basket collateral')
    run.send(None,run.weth,data('deposit()'),sender=run.liquidator,value=10*10**18)
    run.approve(run.weth,morpho,sender=run.liquidator)
    # A successful real liquidation establishes that the oracle change crosses the boundary.
    run.send(None,oracle,data('setPrice(uint256)',5*10**35))
    checkpoint=run.rpc('evm_snapshot',[])
    liquidation=data('liquidate('+MARKET+',address,uint256,uint256,bytes)',market,account,10**18,0,'0x')
    run.send('morpho-unhealthy-liquidation',morpho,liquidation,sender=run.liquidator)
    require(run.rpc('evm_revert',[checkpoint]),'unhealthy baseline reset failed')
    stake=run.call(run.diamond,'basketCollateralPosition(uint256,uint256)((uint256,uint256,uint256))',position,run.basket_id)
    global_stake=run.call(run.diamond,'stakePosition(uint256)((uint256,uint16,uint256,uint256))',position)
    # Keep actual funded reward accounting in the comparison, rather than only an empty claim view.
    run.warp(25*3600)
    key=run.basket_keys[0]
    run.swap(None,key,key[0].lower()!=run.token.lower(),-10**14)
    for asset in (run.token,run.weth):
        run.send(None,run.diamond,data('settleProtocolPoolRevenue(bytes32,address)',run.pool_id(key),asset))
    rewards=run.call(run.diamond,'getBasketRewards(uint256,uint256)(address[],uint256[])',position,run.basket_id)
    require(any(int(v)>0 for v in rewards[1]),'reward comparison has no funded reward')
    run.approve(run.token,morpho)
    run.send('morpho-direct-topup',morpho,data('supplyCollateral('+MARKET+',uint256,address,bytes)',market,60*10**18,account,'0x'))
    run.send('morpho-topup-sync',run.diamond,data('syncMorpho(uint256,bytes32)',position,market_id))
    view=run.scalar(run.diamond,'morphoPositionMarket(uint256,bytes32)((uint256,uint256,uint256,uint256,bool))',position,market_id)
    require(list(map(int,view[:3]))==[80*10**18,140*10**18,60*10**18],'direct top-up incorrectly changes tracked collateral')
    require(stake==run.call(run.diamond,'basketCollateralPosition(uint256,uint256)((uint256,uint256,uint256))',position,run.basket_id), 'direct top-up grants basket stake')
    require(global_stake==run.call(run.diamond,'stakePosition(uint256)((uint256,uint16,uint256,uint256))',position),'direct top-up grants STATICS stake')
    require(rewards==run.call(run.diamond,'getBasketRewards(uint256,uint256)(address[],uint256[])',position,run.basket_id),'direct top-up grants funded rewards')
    run.govern('morpho-exit-only','setMorphoMarketMode(bytes32,uint8)',market_id,2)
    run.send('morpho-exit-deploy-blocked',run.diamond,
             data('deployMorphoCollateral(uint256,bytes32,uint256)',position,market_id,10**18),
             error='MarketNotActive(bytes32)')
    run.send('morpho-exit-borrow-blocked',run.diamond,
             data('borrowMorphoUsd(uint256,bytes32,uint256,uint256,address)',position,market_id,10**18,MAX,run.alice),
             error='MarketNotActive(bytes32)')
    run.approve(run.weth,run.diamond)
    debt_before = int(run.scalar(
        run.diamond,'morphoPositionMarket(uint256,bytes32)((uint256,uint256,uint256,uint256,bool))',
        position,market_id)[3])
    run.send('morpho-exit-repay',run.diamond,
             data('repayMorphoUsd(uint256,bytes32,uint256,uint256,uint256)',position,market_id,10**18,0,10**18))
    debt_after = int(run.scalar(
        run.diamond,'morphoPositionMarket(uint256,bytes32)((uint256,uint256,uint256,uint256,bool))',
        position,market_id)[3])
    require(debt_before > debt_after and debt_after > 0, 'ExitOnly repayment did not reduce borrow shares')
    error_healthy=data('Error(string)','position is healthy')
    run.send('morpho-healthy-liquidation',morpho,liquidation,error=error_healthy)
    withdrawal=data('withdrawUntrackedMorphoCollateral(uint256,bytes32,uint256,address)',position,market_id,60*10**18,run.alice)
    run.send('morpho-unsafe-surplus',run.diamond,withdrawal,error=data('Error(string)','insufficient collateral'))
    run.send(None,oracle,data('setPrice(uint256)',10**36))
    run.send('morpho-surplus-withdrawal',run.diamond,withdrawal)
    run.send('morpho-recall',run.diamond,data('recallMorphoCollateral(uint256,bytes32,uint256)',position,market_id,5*10**18))
    run.send(None,oracle,data('setPrice(uint256)',5*10**35))
    collateral_before = int(run.scalar(run.token,'balanceOf(address)(uint256)',run.liquidator))
    run.send('morpho-final-liquidation',morpho,liquidation,sender=run.liquidator)
    seized = int(run.scalar(run.token,'balanceOf(address)(uint256)',run.liquidator)) - collateral_before
    require(seized >= 10**18, 'liquidator did not receive the seized basket collateral')
    run.send('morpho-loss-sync',run.diamond,data('syncMorpho(uint256,bytes32)',position,market_id))
    final=run.scalar(run.diamond,'morphoPositionMarket(uint256,bytes32)((uint256,uint256,uint256,uint256,bool))',position,market_id)
    require(int(final[0])==74*10**18 and int(final[1])==74*10**18,'liquidation did not synchronize tracked loss')
    run.send('morpho-liquidator-redemption',run.diamond,
             data('redeem(uint256,uint256,address,uint256[])',run.basket_id,10**18,run.liquidator,[0,0]),
             sender=run.liquidator)
    require(int(run.scalar(run.token,'balanceOf(address)(uint256)',run.liquidator)) == collateral_before + seized - 10**18,
            'liquidator did not redeem seized collateral')
    require(set(run.required)==MANDATORY,'later Morpho scenario missing')
    validate_cases(root,run.required)
    save(root/'case-requirements.json',run.required)
    save(root/'summary.json',dict(status='pass',kind='local-anvil-later-morpho',sourceCommit=os.environ['HEAD_COMMIT'],
        mandatoryCases=len(MANDATORY),upstreamRevision=command('git','-C',str(repo),'rev-parse','HEAD:verification/morpho/vendor/morpho-blue'),
        upstreamRuntimeKeccak='0x'+keccak(bytes.fromhex(run.code(morpho)[2:])).hex()))
