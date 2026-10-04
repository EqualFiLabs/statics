#!/usr/bin/env python3
"""Mined POL abuse checks on the canonical rehearsal's disposable Anvil only."""
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.parse import urlparse
from urllib.request import Request, urlopen

REBALANCE = 'rebalanceProtocolPolPositions((bytes32,(uint256,uint256,uint256)[],(int24,int24,uint128,uint256,uint256)[],uint256,uint256,uint256))'
POOL_VIEW = 'protocolPool(bytes32)((bytes32,(address,address,uint24,int24,address),uint8,bool,uint256,address,address,bool,bool,uint16,uint256))'
POSITION_VIEW = 'protocolPolPosition(uint256)((uint256,bytes32,address,uint256,int24,int24,uint128,bool))'
OPEN_EVENT = 'ProtocolPolPositionOpened(bytes32,uint256,address,uint256,int24,int24,uint128,uint256,uint256)'
FEE_EVENT = 'ManagedPositionFeesCollected(bytes32,uint256,address,uint256,uint256)'
CLOSE_EVENT = 'ProtocolPolPositionClosed(bytes32,uint256,uint256,uint256)'
MAX = 2**256 - 1
ZERO = '0x' + '0'*64


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def values(output):
    decoded=json.loads(output)
    if isinstance(decoded,dict):
        assert decoded.get('success') is True and not decoded.get('errors')
        decoded=decoded['data']
    assert isinstance(decoded,list)
    return decoded


def abi(value):
    if isinstance(value, tuple):
        return '(' + ','.join(map(abi, value)) + ')'
    if isinstance(value, list):
        return '[' + ','.join(map(abi, value)) + ']'
    return str(value)


class Rehearsal:
    def __init__(self, environment=os.environ):
        self.env = environment
        self.url = environment['RPC_URL']
        parsed = urlparse(self.url)
        if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or parsed.username or parsed.password:
            raise ValueError('explicit local Anvil required')
        self.root = Path(environment['RUN_DIR'])
        self.failed = self.root/'expected-reverts'
        self.failed.mkdir(exist_ok=True)
        self.diamond = environment['STATICS_DIAMOND_ADDRESS']
        self.pool = environment['POOL_ID']
        self.foreign = environment['FOREIGN_POOL_ID']
        self.inactive = environment['INACTIVE_POOL_ID']
        self.assets = [environment['CURRENCY0'], environment['CURRENCY1']]
        self.operator = environment['POL_OPERATOR']
        self.managers = [environment['STATICS_LIQUIDITY_MANAGER_ADDRESS']]
        self.posm = environment['POSITION_MANAGER']
        self.state_view = environment['STATE_VIEW']
        self.pool_manager = environment['POOL_MANAGER']
        self.permit2 = environment['PERMIT2']
        self.selector = command('cast', 'sig', REBALANCE)
        self.open_topic = command('cast', 'keccak', OPEN_EVENT)
        self.fee_topic = command('cast', 'keccak', FEE_EVENT)
        self.close_topic = command('cast', 'keccak', CLOSE_EVENT)
        self.rpc('anvil_nodeInfo', [])
        assert int(self.rpc('eth_chainId', []), 16) == 4663
        self.evidence = self.root/'selector-execution.jsonl'
        self.checks = []

    def rpc(self, method, params):
        raw = json.dumps({'jsonrpc':'2.0', 'id':1, 'method':method, 'params':params}).encode()
        with urlopen(Request(self.url, raw, {'Content-Type':'application/json'}), timeout=30) as stream:
            value = json.load(stream)
        if 'error' in value:
            raise RuntimeError('local Anvil RPC failed: ' + method)
        return value['result']

    def call(self, address, signature, *args):
        return values(command('cast', 'call', address, signature, *map(abi, args), '--rpc-url', self.url, '--json'))

    def scalar(self, address, signature, *args):
        return self.call(address, signature, *args)[0]

    def account(self, pool):
        return self.scalar(self.diamond, 'protocolPolCustodyAccount(bytes32)(bytes32)', pool)

    def reserve(self, pool):
        return [int(self.scalar(self.diamond, 'reservedByAccount(bytes32,address)(uint256)', self.account(pool), a)) for a in self.assets]

    def ids(self):
        return [int(x) for x in self.scalar(self.diamond, 'protocolPolPositionIds(bytes32)(uint256[])', self.pool)]

    def position(self, position):
        return self.scalar(self.diamond, POSITION_VIEW, position)

    def active(self):
        return [i for i in self.ids() if self.position(i)[7]]

    def deadline(self):
        return int(self.rpc('eth_getBlockByNumber', ['latest', False])['timestamp'], 16) + 3600

    def data(self, pool, closes, opens, limits=None, deadline=None):
        limits = limits if limits is not None else [sum(x[3+i] for x in opens) for i in (0,1)]
        return command('cast', 'calldata', REBALANCE,
                       abi((pool, closes, opens, *limits, self.deadline() if deadline is None else deadline)))

    def bands(self, count=3, liquidity=10**10):
        reserve = self.reserve(self.pool)
        maxima = [q//(count*2) for q in reserve]
        ranges = [(-120,120), (240,600), (-600,-240)]
        return [(*ranges[i%3], liquidity, *maxima) for i in range(count)]

    def snapshot(self):
        value = {'nextTokenId':self.scalar(self.posm, 'nextTokenId()(uint256)'), 'positions':{}, 'pools':{}, 'tokens':{}}
        for pool in (self.pool, self.foreign, self.inactive):
            value['pools'][pool] = {'pool':self.scalar(self.diamond, POOL_VIEW, pool), 'reserve':self.reserve(pool),
                'liquidity':self.scalar(self.state_view, 'getLiquidity(bytes32)(uint128)', pool),
                'feeGrowth':self.call(self.state_view, 'getFeeGrowthGlobals(bytes32)(uint256,uint256)', pool),
                'slot':self.call(self.state_view, 'getSlot0(bytes32)(uint160,int24,uint24,uint24)', pool),
                'ids':self.scalar(self.diamond, 'protocolPolPositionIds(bytes32)(uint256[])', pool),
                'pending':[self.scalar(self.env['STATICS_SWAP_FEE_HOOK_ADDRESS'], 'pendingProtocolPol(bytes32,address)(uint256)', pool,a) for a in self.assets]}
        for i in self.ids():
            p = self.position(i)
            value['positions'][str(i)] = {'position':p, 'binding':self.scalar(self.diamond, 'posmBinding(uint256)(bytes32)', p[3])}
            if p[7]:
                value['positions'][str(i)].update(owner=self.scalar(self.posm, 'ownerOf(uint256)(address)', p[3]),
                    liquidity=self.scalar(self.posm, 'getPositionLiquidity(uint256)(uint128)', p[3]))
        for a in self.assets:
            value['tokens'][a] = {'globalReserve':self.scalar(self.diamond,'globalReservedByToken(address)(uint256)',a),
                'treasury':self.scalar(self.diamond,'treasuryAccrued(address)(uint256)',a),
                'balances':{who:self.scalar(a,'balanceOf(address)(uint256)',who) for who in
                            [self.diamond,self.operator,self.env['TRADER'],self.env['CREATOR'],*self.managers]}}
        value['userLeg'] = self.scalar(self.diamond,'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))',self.env['USER_POSITION'],self.pool)
        return value

    def check(self, label, detail):
        self.checks.append(label)
        with (self.root/'results.jsonl').open('a') as out:
            out.write(json.dumps({'suite':'protocol-pol-rebalance','scenario':label,'status':'pass','detail':detail})+'\n')
        print('[protocol-pol-rebalance] ' + label, flush=True)

    def send(self, label, data, sender=None, expected_error=None, success_calls=()):
        before = self.snapshot()
        sender = sender or self.operator
        self.rpc('anvil_impersonateAccount', [sender])
        tx = self.rpc('eth_sendTransaction', [{'from':sender,'to':self.diamond,'data':data,
            'gas':hex(15000000),'gasPrice':self.rpc('eth_gasPrice',[])}])
        receipt = None
        for _ in range(100):
            receipt = self.rpc('eth_getTransactionReceipt',[tx])
            if receipt is not None:break
            time.sleep(.1)
        if receipt is None:raise AssertionError('mined receipt missing: ' + label)
        expected_status = '0x0' if expected_error else '0x1'
        transaction = self.rpc('eth_getTransactionByHash',[tx])
        assert transaction['to'].lower() == self.diamond.lower() and transaction['input'] == data
        assert transaction['from'].lower() == sender.lower()
        path = (self.failed if expected_error else self.root)/('pol-rebalance-'+label+'.json')
        path.write_text(json.dumps(receipt,indent=2)+'\n')
        transaction_path=self.root/('pol-rebalance-'+label+'-transaction.json')
        transaction_path.write_text(json.dumps(transaction,indent=2)+'\n')
        if receipt['status'] != expected_status:raise AssertionError('unexpected mined status: ' + label)
        if expected_error:
            trace = self.rpc('debug_traceTransaction',[tx,{'tracer':'callTracer'}])
            error_selector = command('cast','sig',expected_error)
            assert trace.get('error') and error_selector.removeprefix('0x').lower() in trace.get('output','').lower(), label
            calls = []
            def visit(call):
                calls.append(call)
                for child in call.get('calls',[]):visit(child)
            visit(trace)
            for signature, minimum in success_calls:
                selector = command('cast','sig',signature)
                assert sum(c.get('input','').startswith(selector) and c.get('to','').lower() in [m.lower() for m in self.managers] and not c.get('error') for c in calls)>=minimum, label+' did not reach '+signature
            after = self.snapshot()
            assert before == after, label+' changed financial state after reverting'
            (self.failed/(label+'-state.json')).write_text(json.dumps({'before':before,'after':after,'trace':trace,'errorSelector':error_selector},indent=2)+'\n')
            self.check(label,'Mined expected revert, exact error, reached calls and unchanged custody/POSM/accounting state')
        else:
            after = self.snapshot()
            assert before['pools'][self.foreign] == after['pools'][self.foreign], label+' moved foreign POL'
            assert before['pools'][self.inactive] == after['pools'][self.inactive]
            assert before['userLeg'] == after['userLeg'], label+' changed Treasury/user LP'
            for a in self.assets:
                balances = after['tokens'][a]['balances']
                assert int(after['tokens'][a]['globalReserve']) <= int(balances[self.diamond])
                assert balances[self.operator] == before['tokens'][a]['balances'][self.operator]
                assert all(int(balances[m]) == 0 for m in self.managers), label+' stranded manager tokens'
            self.check(label,'Mined success, same-PoolId custody, solvency, signer/user isolation and manager refunds')
        with self.evidence.open('a') as out:
            out.write(json.dumps({'selector':self.selector,'signature':REBALANCE,'scenario':'protocol-pol-rebalance',
                'label':label,'transactionHash':tx,'status':receipt['status'],'to':self.diamond,
                'calldata':data,'sender':sender,'receiptFile':str(path.relative_to(self.root)),
                'transactionFile':str(transaction_path.relative_to(self.root)),
                'stateFile':str((self.failed/(label+'-state.json')).relative_to(self.root)) if expected_error else None})+'\n')
        return receipt,before,after

    def events(self, receipt, topic, signature):
        return [(int(log['topics'][2],16),values(command('cast','abi-decode',signature,log['data'],'--json')))
            for log in receipt['logs'] if log['address'].lower()==self.diamond.lower() and log['topics'][0]==topic]

    def collected_fees(self, receipt, positions):
        expected={int(self.position(i)[3]):self.position(i)[2].lower() for i in positions}
        seen=set()
        totals=[0,0]
        for log in receipt['logs']:
            if log['topics'][0] != self.fee_topic:continue
            token=int(log['topics'][2],16)
            assert token in expected and token not in seen
            assert log['address'].lower()==expected[token]
            assert log['topics'][1]==self.pool
            assert ('0x'+log['topics'][3][-40:]).lower()==self.diamond.lower()
            seen.add(token)
            fees=values(command('cast','abi-decode','f()(uint256,uint256)',log['data'],'--json'))
            totals=[total+int(fee) for total,fee in zip(totals,fees)]
        assert seen==set(expected), 'exact per-position fee harvest evidence missing'
        return totals

    def rebalance(self, label, closes, opens, require_fees=False):
        receipt,before,after = self.send(label,self.data(self.pool,[(i,0,0) for i in closes],opens))
        opened = self.events(receipt,self.open_topic,'f()(uint256,int24,int24,uint128,uint256,uint256)')
        closed = self.events(receipt,self.close_topic,'f()(uint256,uint256)')
        assert len(opened)==len(opens) and [i for i,_ in closed]==closes
        fees=self.collected_fees(receipt,closes)
        for asset in (0,1):
            returned=sum(int(values[asset]) for _,values in closed)
            spent=sum(int(values[4+asset]) for _,values in opened)
            assert after['pools'][self.pool]['reserve'][asset] == before['pools'][self.pool]['reserve'][asset]+returned-spent
            assert spent<=sum(leg[3+asset] for leg in opens)
            key=self.assets[asset]
            assert int(after['tokens'][key]['treasury'])==int(before['tokens'][key]['treasury'])+fees[asset]
            assert int(after['tokens'][key]['globalReserve'])==int(before['tokens'][key]['globalReserve'])+returned-spent
            assert int(after['tokens'][key]['balances'][self.diamond])==int(before['tokens'][key]['balances'][self.diamond])+returned-spent+fees[asset]
        if require_fees:
            assert any(int(after['tokens'][a]['treasury'])>int(before['tokens'][a]['treasury']) for a in self.assets), 'real POL fees not credited to Treasury'
        for i in closes:
            p=self.position(i)
            assert not p[7] and int(p[6])==0 and self.scalar(self.diamond,'posmBinding(uint256)(bytes32)',p[3])==ZERO
            try:self.scalar(self.posm,'ownerOf(uint256)(address)',p[3])
            except subprocess.CalledProcessError as error:
                assert 'NOT_MINTED' in error.stderr, 'ownerOf failure does not prove a burned NFT'
            else:raise AssertionError('closed POSM NFT not burned')
        for (i,values),leg in zip(opened,opens):
            p=self.position(i)
            assert p[2].lower()==self.managers[-1].lower() and int(p[6])==leg[2] and p[7]
            assert [int(p[4]),int(p[5])]==list(leg[:2])
            assert self.scalar(self.posm,'ownerOf(uint256)(address)',p[3]).lower()==p[2].lower()
            assert int(self.scalar(self.posm,'getPositionLiquidity(uint256)(uint128)',p[3]))==leg[2]
            binding=command('cast','keccak',command('cast','abi-encode','f(bytes32,uint256)',command('cast','keccak','statics.position.binding.protocol.pol'),str(i)))
            assert self.scalar(self.diamond,'posmBinding(uint256)(bytes32)',p[3])==binding
        assert int(after['pools'][self.pool]['pool'][10])==len(self.active())
        self.check(label+'-principal-accounting','Exact per-asset principal returns minus gross spends; LP fees excluded from POL')
        return [i for i,_ in opened],dict(closed),dict(opened)

    def swap(self, direction, label):
        common=str(Path(self.env['REHEARSAL_SCRIPT_DIR'])/'lib/common.sh')
        subprocess.run(['bash','-c',
            'source "$1"; load_current_run; require_local_chain; v4_swap_exact_in 14 "$2" "$3" 3000 60 "$4" "$5" 10000000000000000 "$6"',
            'rehearsal',common,*self.assets,self.env['STATICS_SWAP_FEE_HOOK_ADDRESS'],direction,'pol-rebalance-'+label],check=True)

    def close(self, label, position):
        before=self.snapshot()
        data=command('cast','calldata','closeProtocolPolPosition(uint256,uint256,uint256,uint256)',str(position),'0','0',str(self.deadline()))
        tx=self.rpc('eth_sendTransaction',[{'from':self.operator,'to':self.diamond,'data':data,'gas':hex(3000000)}])
        receipt=self.rpc('eth_getTransactionReceipt',[tx])
        assert receipt and receipt['status']=='0x1'
        (self.root/('pol-rebalance-'+label+'.json')).write_text(json.dumps(receipt)+'\n')
        closed=self.events(receipt,self.close_topic,'f()(uint256,uint256)')
        assert len(closed)==1 and closed[0][0]==position
        after=self.snapshot()
        fees=self.collected_fees(receipt,[position])
        for asset in (0,1):
            assert after['pools'][self.pool]['reserve'][asset]==before['pools'][self.pool]['reserve'][asset]+int(closed[0][1][asset])
            a=self.assets[asset]
            assert int(after['tokens'][a]['treasury'])==int(before['tokens'][a]['treasury'])+fees[asset]
        assert not self.position(position)[7]
        self.check(label,'Authorized exit returns principal to the same POL account')

    def govern(self, label, signature, *args):
        data=command('cast','calldata',signature,*map(abi,args))
        common=str(Path(self.env['REHEARSAL_SCRIPT_DIR'])/'lib/common.sh')
        subprocess.run(['bash','-c','source "$1"; load_current_run; require_local_chain; timelock_call "$2" 0 "$3" "$4"',
                        'rehearsal',common,self.diamond,data,'pol-rebalance-'+label],check=True)


def run(r):
    opens=r.bands()
    bad=opens[:-1]+[(0,0,*opens[-1][2:])]
    mint='mintManagedPosition(((address,address,uint24,int24,address),int24,int24,uint256,uint256,uint256,uint256),address)'
    exit_sig='exitManagedPosition((uint256,uint128,uint256,uint256,uint256,address))'
    r.send('seed-late-mint-rollback',r.data(r.pool,[],bad),expected_error='InvalidPositionParameters()',success_calls=[(mint,2)])
    ids,_,opened=r.rebalance('seed-three-band-portfolio',[],opens)
    assert int(opened[ids[0]][4])>0 and int(opened[ids[0]][5])>0
    assert int(opened[ids[1]][4])>0 and int(opened[ids[1]][5])==0
    assert int(opened[ids[2]][4])==0 and int(opened[ids[2]][5])>0
    seed_id=ids[0]
    r.swap('true','earned-fees0')
    r.swap('false','earned-fees1')
    r.check('dual-and-both-single-sided','Exact minted debits prove tight dual-sided fee and both single-sided bands')
    closes=[(ids[0],0,0)]
    single=r.bands(1)
    invalid=[
        ('unauthorized',r.data(r.pool,closes,single),'OnlyProtocolPolOperator(address)',r.env['TRADER']),
        ('expired',r.data(r.pool,closes,single,deadline=0),'ProtocolPolRebalanceExpired(uint256)',None),
        ('no-opens',r.data(r.pool,closes,[]),'InvalidProtocolPolRebalanceLegs()',None),
        ('nine-opens',r.data(r.pool,closes,r.bands(9)),'InvalidProtocolPolRebalanceLegs()',None),
        ('nine-closes',r.data(r.pool,closes*9,single),'InvalidProtocolPolRebalanceLegs()',None),
        ('duplicate-close',r.data(r.pool,closes*2,single),'DuplicateProtocolPolClose(uint256)',None),
        ('unknown-close',r.data(r.pool,[(MAX,0,0)],single),'ProtocolPolPositionNotFound(uint256)',None),
        ('foreign-close',r.data(r.foreign,closes,single),'ProtocolPolPositionPoolMismatch(uint256,bytes32,bytes32)',None),
        ('unregistered-pool',r.data(ZERO,[],single),'ProtocolPoolNotRegistered(bytes32)',None),
        ('inactive-pool',r.data(r.inactive,[],single),'ProtocolPolNotActivated(bytes32)',None),
        ('gross-debit0',r.data(r.pool,closes,single,[single[0][3]-1,single[0][4]]),'ProtocolPolAggregateDebitExceeded(uint256,uint256)',None),
        ('gross-debit1',r.data(r.pool,closes,single,[single[0][3],single[0][4]-1]),'ProtocolPolAggregateDebitExceeded(uint256,uint256)',None),
        ('sum-overflow0',r.data(r.pool,[],[(-120,120,10**10,MAX,0),(-120,120,10**10,1,0)],[MAX,0]),'Panic(uint256)',None),
        ('sum-overflow1',r.data(r.pool,[],[(-120,120,10**10,0,MAX),(-120,120,10**10,0,1)],[0,MAX]),'Panic(uint256)',None),
        ('close-minimum',r.data(r.pool,[(ids[0],MAX,MAX)],single),'InvalidPositionParameters()',None),
    ]
    for label,data,error,sender in invalid:r.send(label,data,sender,expected_error=error)
    own=r.reserve(r.pool)
    assert r.reserve(r.foreign)[0]>0 and r.reserve(r.foreign)[1]>0
    for asset in (0,1):
        maxima=[0,0];maxima[asset]=own[asset]+1
        r.send('foreign-custody-debit'+str(asset),r.data(r.pool,[],[(-120,120,10**10,*maxima)]),
               expected_error='InsufficientAccountReservation(bytes32,address,uint256,uint256)')
    for label,leg,error in [('zero-liquidity',(-120,120,0,*own),'InvalidPositionParameters()'),
                           ('equal-ticks',(0,0,10**10,*own),'InvalidPositionParameters()'),
                           ('reversed-ticks',(120,-120,10**10,*own),'InvalidPositionParameters()'),
                           ('unaligned-ticks',(-119,120,10**10,*own),'TickMisaligned(int24,int24)')]:
        r.send(label,r.data(r.pool,closes,[leg]),expected_error=error)
    r.send('replace-late-mint-rollback',r.data(r.pool,[(i,0,0) for i in ids],bad),
           expected_error='InvalidPositionParameters()',success_calls=[(exit_sig,3),(mint,2)])
    # Guardian pause is a mined transaction; authorized exits remain live.
    guardian=r.env['GUARDIAN']
    r.rpc('anvil_impersonateAccount',[guardian])
    pause=command('cast','calldata','pause(uint256)',str(32))
    h=r.rpc('eth_sendTransaction',[{'from':guardian,'to':r.diamond,'data':pause,'gas':hex(1000000)}])
    receipt=r.rpc('eth_getTransactionReceipt',[h]);assert receipt and receipt['status']=='0x1'
    (r.root/'pol-rebalance-pause.json').write_text(json.dumps(receipt)+'\n')
    r.send('paused',r.data(r.pool,closes,single),expected_error='ActionPaused(uint256)')
    r.close('exit-while-paused',ids[-1])
    ids=ids[:-1]
    r.govern('unpause','unpause(uint256)',32)
    # Compile the deployed replacement from this run's exact production artifact.
    artifact=json.loads((Path(r.env['PHASE_ONE_OUT'])/'StaticsLiquidityManager.sol/StaticsLiquidityManager.json').read_text())
    args=command('cast','abi-encode','f(address,address,address,address)',r.diamond,r.posm,r.pool_manager,r.permit2)
    tx=r.rpc('eth_sendTransaction',[{'from':r.env['DEPLOYER'],'data':'0x'+artifact['bytecode']['object'].removeprefix('0x')+args[2:],'gas':hex(10000000)}])
    receipt=r.rpc('eth_getTransactionReceipt',[tx]);assert receipt and receipt['status']=='0x1'
    (r.root/'pol-rebalance-deploy-replacement.json').write_text(json.dumps(receipt)+'\n')
    replacement=receipt['contractAddress']
    r.govern('replace-manager','replaceLiquidityManager(address)',replacement)
    r.managers.append(replacement)
    ids,_,_=r.rebalance('replace-old-manager-eight-opens',ids,r.bands(8),require_fees=True)
    r.send('closed-id-replay',r.data(r.pool,[(seed_id,0,0)],r.bands(1)),expected_error='ProtocolPolPositionNotFound(uint256)')
    ids,_,_=r.rebalance('eight-closes-eight-opens',ids,r.bands(8))
    late=r.bands(3);late[-1]=(0,0,*late[-1][2:])
    r.send('eight-close-late-open-rollback',r.data(r.pool,[(i,0,0) for i in ids],late),
           expected_error='InvalidPositionParameters()',success_calls=[(exit_sig,8),(mint,2)])
    ids,_,_=r.rebalance('eight-closes-three-opens',ids,r.bands(3))
    r.govern('begin-decommission','beginGeneralPoolDecommission(bytes32)',r.pool)
    r.send('decommission-late-open-rollback',r.data(r.pool,[(i,0,0) for i in ids],r.bands()),
           expected_error='ProtocolPoolDecommissioned(bytes32)',success_calls=[(exit_sig,3)])
    for i in ids:r.close('terminal-close-'+str(i),i)
    assert not r.active()
    r.govern('finalize-decommission','finalizeGeneralPoolDecommission(bytes32)',r.pool)
    assert r.reserve(r.pool)==[0,0]
    for a in r.assets:
        assert int(r.scalar(r.diamond,'globalReservedByToken(address)(uint256)',a))<=int(r.scalar(a,'balanceOf(address)(uint256)',r.diamond))
    r.check('terminal-decommission','All protocol POSMs closed, zero PoolId reserves and globally backed liabilities')
    (r.root/'pol-rebalance-summary.json').write_text(json.dumps({'checks':r.checks,'productionSourceChanged':False,'formalVerificationAdded':False},indent=2)+'\n')


if __name__ == '__main__':
    run(Rehearsal())
