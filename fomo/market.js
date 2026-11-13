// FOMO Market: fixed-price listings + live auctions. Cards escrowed in the market contract; wallet signs everything.
import {ethers} from './vendor/ethers.min.js';
const MABI=['function nextId() view returns (uint256)','function listings(uint256) view returns (address seller,uint96 id,uint64 amount,uint64 end,uint128 price,address bidder,uint128 bid,bool active)',
 'function feeBps() view returns (uint16)','function quote(uint256,uint256) view returns (uint256 fee,address royaltyTo,uint256 royalty,uint256 toSeller)',
 'function list(uint256,uint256,uint256,uint256) returns (uint256)','function buy(uint256) payable','function bid(uint256) payable','function settle(uint256)','function cancel(uint256)',
 'function credit(address) view returns (uint256)','function withdraw()','function paused() view returns (bool)'];
const CABI=['function isApprovedForAll(address,address) view returns (bool)','function setApprovalForAll(address,bool)','function balanceOfBatch(address[],uint256[]) view returns (uint256[])'];
const NAMES={101:'Aura',102:'Neon Frame',103:'Star Boost',104:'Halo of Seven'};
const $=s=>document.querySelector(s);
let M={rows:[],fee:250,bal:{},credit:0n,busy:false,loaded:false};
function mnet(){const n=window.shopNet&&shopNet();const C=typeof CFG!=='undefined'?CFG:null;if(!n||!C)return null;const k=n.main?'mainnet':'testnet';const m=C[k]&&C[k].market;return m?{...n,market:m}:null}
const eth=w=>ethers.formatEther(w),unit=n=>n.main?'ETH':'test ETH';
const nm=id=>id<=7?`${id}★ ${TIERS[id].n}`:(NAMES[id]||('#'+id));
function left(end){const s=Number(end)-Math.floor(Date.now()/1000);if(s<=0)return 'ended';const h=Math.floor(s/3600),m=Math.floor(s%3600/60),x=s%60;return h?`${h}h ${m}m`:`${m}m ${x}s`}
async function load(){const n=mnet();if(!n)return;const p=new ethers.JsonRpcProvider(n.rpc,n.id,{staticNetwork:true});const m=new ethers.Contract(n.market,MABI,p);
 try{const [nx,fee]=await Promise.all([m.nextId(),m.feeBps()]);M.fee=Number(fee);const ids=[];for(let i=Number(nx)-1;i>=1&&ids.length<60;i--)ids.push(i);
  const ls=await Promise.all(ids.map(i=>m.listings(i)));M.rows=ids.map((lid,k)=>({lid,...ls[k].toObject()})).filter(r=>r.active);
  if(acct){const c=new ethers.Contract(n.addr,CABI,p);const a=[1,2,3,4,5,6,7,101,102,103,104];const b=await c.balanceOfBatch(a.map(()=>acct),a);M.bal={};a.forEach((i,k)=>M.bal[i]=b[k]);M.credit=await m.credit(acct)}else{M.bal={};M.credit=0n}
  M.loaded=true;render()}catch(e){console.warn('market read',e)}}
let lastA=null;
function render(full=true){const box=$('#mkList');if(!box)return;const n=mnet();if(n&&acct!==lastA){lastA=acct;load()}
 if(!n){$('#mkNet').textContent='SOON';box.innerHTML='<p class="muted">The market opens once the market contract is live.</p>';$('#mkSell').innerHTML='';sellKey='';return}
 $('#mkNet').textContent=n.main?'LIVE · BASE':'TESTNET';$('#mkFee').textContent=(M.fee/100)+'%';
 const me=(acct||'').toLowerCase();if(!full&&!M.rows.some(r=>r.end>0n))return;
 box.innerHTML=!M.loaded?'<p class="muted">Loading…</p>':(M.rows.length?M.rows.map(r=>{const auc=r.end>0n,ended=auc&&Number(r.end)<=Date.now()/1000,mine=r.seller.toLowerCase()===me;
  const cur=auc?(r.bid>0n?r.bid:r.price):r.price;const id=Number(r.id);
  const act=mine?(r.bidder===ethers.ZeroAddress?`<button class="btn sm ghost mkc" data-l="${r.lid}">Cancel</button>`:(ended?`<button class="btn sm mks" data-l="${r.lid}">Settle</button>`:'<span class="muted">Live</span>')):
   (auc?(ended?`<button class="btn sm mks" data-l="${r.lid}">Settle</button>`:`<button class="btn sm mkb" data-l="${r.lid}">Bid</button>`):`<button class="btn sm mkbuy" data-l="${r.lid}">Buy</button>`);
  return `<div class="shopitem">${id<=7?nftHTML(id):''}<div class="info"><b>${nm(id)}</b>${r.amount>1n?' ×'+r.amount:''}<br><span class="pill">${auc?(ended?'AUCTION ENDED':'AUCTION · '+left(r.end)):'BUY NOW'}</span><div class="price">${eth(cur)} ${unit(n)}${auc?(r.bid>0n?' top bid':' reserve'):''}</div><span class="muted" style="font-size:11px">Seller ${short(r.seller)}${auc&&r.bid>0n?' · top '+short(r.bidder):''}</span></div><div style="width:auto">${act}</div></div>`}).join(''):'<p class="muted">No listings yet. Be the first to list a card.</p>');
 box.querySelectorAll('.mkbuy').forEach(b=>b.onclick=()=>buy(+b.dataset.l));box.querySelectorAll('.mkb').forEach(b=>b.onclick=()=>bidUI(+b.dataset.l));
 box.querySelectorAll('.mks').forEach(b=>b.onclick=()=>tx('settle',+b.dataset.l,0n,'Settled'));box.querySelectorAll('.mkc').forEach(b=>b.onclick=()=>tx('cancel',+b.dataset.l,0n,'Listing cancelled'));
 if(full)renderSell(n);}
let sellKey='';
function renderSell(n){const key=[acct,M.loaded,M.credit,...[1,2,3,4,5,6,7,101,102,103,104].map(i=>M.bal[i])].join('|');if(key===sellKey&&$('#mkSell').innerHTML)return;sellKey=key;
const own=[1,2,3,4,5,6,7,101,102,103,104].filter(i=>M.bal[i]>0n);
 $('#mkSell').innerHTML=!acct?'<p class="muted">Connect a wallet to list your cards.</p>':(!own.length?'<p class="muted">You have no on-chain cards to list yet.</p>':
  `<label class="muted" style="font-size:12px">Card</label><select id="mkCard" class="inp">${own.map(i=>`<option value="${i}">${nm(i)} (you own ${M.bal[i]})</option>`).join('')}</select>
   <label class="muted" style="font-size:12px">Type</label><select id="mkType" class="inp"><option value="0">Buy now (fixed price)</option><option value="3600">Auction · 1 hour</option><option value="86400">Auction · 24 hours</option><option value="259200">Auction · 3 days</option></select>
   <label class="muted" style="font-size:12px" id="mkPL">Price (${unit(n)})</label><input id="mkPrice" class="inp" inputmode="decimal" placeholder="0.01">
   <p class="muted" id="mkQuote" style="font-size:12px;margin:6px 0"></p><button class="btn sm" id="mkGo">List card</button>`)+(M.credit>0n?`<p style="margin-top:10px">You have ${eth(M.credit)} ${unit(n)} to collect. <button class="btn sm" id="mkW">Withdraw</button></p>`:'');
 const pr=$('#mkPrice');if(pr){const q=()=>quoteUI();pr.oninput=q;$('#mkType').onchange=()=>{$('#mkPL').textContent=($('#mkType').value==='0'?'Price':'Reserve (lowest first bid)')+` (${unit(n)})`;q()};$('#mkCard').onchange=q;$('#mkGo').onclick=listUI}
 const w=$('#mkW');if(w)w.onclick=()=>tx('withdraw',null,0n,'Withdrawn');}
async function quoteUI(){const n=mnet(),el=$('#mkQuote');let v;try{v=ethers.parseEther(($('#mkPrice').value||'0').trim())}catch(e){el.textContent='Enter a valid amount';return}if(v===0n){el.textContent='';return}
 const m=new ethers.Contract(n.market,MABI,new ethers.JsonRpcProvider(n.rpc,n.id,{staticNetwork:true}));try{const q=await m.quote(+$('#mkCard').value,v);el.textContent=`At ${eth(v)}: platform fee ${eth(q.fee)} (${M.fee/100}%) · creator royalty ${eth(q.royalty)} · you receive ${eth(q.toSeller)} ${unit(n)}`}catch(e){el.textContent=''}}
async function ctx(){const n=mnet();if(!prov||!acct){openConnect();toast('Connect a wallet first');throw new Error('no wallet')}
 try{await prov.request({method:'wallet_switchEthereumChain',params:[{chainId:n.hex}]})}catch(e){}const bp=new ethers.BrowserProvider(prov);const s=await bp.getSigner();return {n,m:new ethers.Contract(n.market,MABI,s),c:new ethers.Contract(n.addr,CABI,s)}}
function done(title,n,hash,extra=''){modal(`<h2 class="center">${title}</h2><p class="center">${extra}</p><div class="row" style="margin-top:12px"><a class="btn sm" style="text-align:center;text-decoration:none" target="_blank" href="${n.exp}/tx/${hash}">Transaction</a><button class="btn sm ghost" onclick="closeModal()">Close</button></div>`);load();window.chainUI&&window.chainUI.load()}
async function send(fn){if(M.busy)return;M.busy=true;try{toast('Confirm in your wallet…');const t=await fn();toast('Waiting for the network…');const r=await t.wait();if(r.status!==1)throw new Error('reverted');return t.hash}
 catch(e){toast((e.shortMessage||e.reason||e.message||'Failed').slice(0,90));throw e}finally{M.busy=false}}
async function tx(fnName,lid,value,title){let x;try{x=await ctx()}catch(e){return}const h=await send(()=>lid==null?x.m[fnName]():x.m[fnName](lid,{value})).catch(()=>null);if(h)done(title,x.n,h)}
async function listUI(){let x;try{x=await ctx()}catch(e){return}const id=+$('#mkCard').value,dur=+$('#mkType').value;let v;try{v=ethers.parseEther(($('#mkPrice').value||'').trim())}catch(e){toast('Enter a valid price');return}if(v<=0n){toast('Enter a price');return}
 try{if(!(await x.c.isApprovedForAll(acct,x.n.market))){toast('Step 1 of 2: allow the market to hold listed cards');await send(()=>x.c.setApprovalForAll(x.n.market,true))}
  const h=await send(()=>x.m.list(id,1,v,dur));done('Listed!',x.n,h,`${nm(id)} ${dur?'auction':'for sale'} at ${eth(v)} ${unit(x.n)}. Your card is held by the market contract until it sells or you cancel.`)}catch(e){}}
function buy(lid){const r=M.rows.find(r=>r.lid===lid),n=mnet();modal(`<h2 class="center">Buy ${nm(Number(r.id))}</h2><p class="center">Price ${eth(r.price)} ${unit(n)} + gas. Card arrives in the same transaction or nothing happens.</p><div class="row" style="margin-top:12px"><button class="btn sm ghost" onclick="closeModal()">Cancel</button><button class="btn sm" id="mkOk">Buy</button></div>`);
 $('#mkOk').onclick=()=>{closeModal();tx('buy',lid,r.price,'Bought!')}}
function bidUI(lid){const r=M.rows.find(r=>r.lid===lid),n=mnet();const min=r.bid>0n?r.bid*10500n/10000n+1n:r.price;
 modal(`<h2 class="center">Bid on ${nm(Number(r.id))}</h2><p class="center muted">Minimum ${eth(min)} ${unit(n)}. Your ETH is held by the contract and returned automatically if you're outbid. Bids in the last 5 minutes extend the auction.</p><input id="mkBid" class="inp" inputmode="decimal" value="${eth(min)}"><div class="row" style="margin-top:12px"><button class="btn sm ghost" onclick="closeModal()">Cancel</button><button class="btn sm" id="mkOk">Place bid</button></div>`);
 $('#mkOk').onclick=()=>{let v;try{v=ethers.parseEther($('#mkBid').value.trim())}catch(e){toast('Enter a valid bid');return}if(v<min){toast('Bid too low');return}closeModal();tx('bid',lid,v,'Bid placed!')}}
setInterval(()=>{if(document.querySelector('#v-market.on'))render(false)},1000);
setInterval(()=>{if(document.querySelector('#v-market.on'))load()},20000);
window.marketUI={load,render};
let tries=0;const boot=setInterval(()=>{if(typeof CFG!=='undefined'&&CFG){clearInterval(boot);load()}else if(++tries>50)clearInterval(boot)},200);
