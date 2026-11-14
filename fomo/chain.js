// FOMO on-chain layer: reads contract state, mints, evolves, early bonus. Wallet signs; app never holds keys.
import {ethers} from './vendor/ethers.min.js';
const ABI=['function priceOf(uint256) view returns (uint256)','function remaining(uint256) view returns (uint256)','function capOf(uint256) view returns (uint256)',
 'function totalSupply(uint256) view returns (uint256)','function bonusLeft() view returns (uint256)','function bonusMax() view returns (uint256)',
 'function bonusTarget(address) view returns (uint256)','function bonusAddon(address) view returns (uint256)','function balanceOfBatch(address[],uint256[]) view returns (uint256[])',
 'function mint(uint256,uint256) payable','function evolve(uint256,uint256)','function claimBonus()','function revealBonus(address)','function paused() view returns (bool)'];
const ADDON={101:'Aura',102:'Neon Frame',103:'Star Boost',104:'Halo of Seven'};
const $=s=>document.querySelector(s);
let S={prices:{},left:{},bonusLeft:null,bonusMax:500,bal:{},target:0n,addon:0n,ready:false};
const net=()=>window.shopNet&&shopNet();
const rd=()=>{const n=net();return n?new ethers.Contract(n.addr,ABI,new ethers.JsonRpcProvider(n.rpc,n.id,{staticNetwork:true})):null};
const fmt=w=>{const s=ethers.formatEther(w);return s};
async function ensureChain(n){const cur=async()=>parseInt(await prov.request({method:'eth_chainId'}),16);if(await cur()===n.id)return;
 try{await prov.request({method:'wallet_switchEthereumChain',params:[{chainId:n.hex}]})}catch(e){if(e.code===4001)throw e;if(n.id===1)throw e;await prov.request({method:'wallet_addEthereumChain',params:[{chainId:n.hex,chainName:n.name,nativeCurrency:{name:'Ether',symbol:'ETH',decimals:18},rpcUrls:[n.rpc],blockExplorerUrls:[n.exp]}]})}
 for(let i=0;i<60;i++){if(await cur()===n.id)return;await new Promise(r=>setTimeout(r,250))}toast('Switch your wallet to '+n.name+', then try again');throw new Error('wrong chain')}
window.fomoEnsureChain=ensureChain;
async function signerC(){const n=net();if(!prov||!acct){openConnect();toast('Connect a wallet first');throw new Error('no wallet')}await ensureChain(n);const bp=new ethers.BrowserProvider(prov,'any');return {c:new ethers.Contract(n.addr,ABI,await bp.getSigner()),bp,n}}
function nftLink(n,id){return n.main?`https://opensea.io/assets/${n.os||'base'}/${n.addr}/${id}`:`${n.exp}/token/${n.addr}?a=${id}`}
async function load(){const c=rd();if(!c)return;try{
  const ids=[1,2,3,4,5,6,7];const [p1,p3,p7,...rest]=await Promise.all([c.priceOf(1),c.priceOf(3),c.priceOf(7),...ids.map(i=>c.remaining(i)),c.bonusLeft(),c.bonusMax()]);
  S.prices={1:p1,3:p3,7:p7};ids.forEach((i,k)=>S.left[i]=rest[k]);S.bonusLeft=rest[7];S.bonusMax=rest[8];
  if(acct){const a=[1,2,3,4,5,6,7,101,102,103,104];const b=await c.balanceOfBatch(a.map(()=>acct),a);a.forEach((i,k)=>S.bal[i]=b[k]);S.target=await c.bonusTarget(acct);S.addon=await c.bonusAddon(acct)}else{S.bal={};S.target=0n;S.addon=0n}
  S.ready=true;render()}catch(e){console.warn('chain read',e)}}
function render(){const n=net();if(!n)return;
 // shop prices + caps from contract
 document.querySelectorAll('.mintb').forEach(b=>{const t=+b.dataset.t;if(S.prices[t]!=null){b.dataset.p=fmt(S.prices[t]);const pr=b.parentElement.querySelector('.price');if(pr)pr.innerHTML=`${fmt(S.prices[t])} ${n.main?'ETH':'test ETH'} + gas<br><span class="muted" style="font-size:11px">${S.left[t]!=null?S.left[t].toLocaleString()+' left':''}</span>`;if(S.left[t]===0n){b.disabled=true;b.textContent='Sold out'}}});
 // bonus
 const bp=$('#bonusPanel');if(bp){bp.style.display='block';$('#bonusCount').textContent=S.bonusLeft==null?'…':`${S.bonusLeft} of ${S.bonusMax} early bonuses left`;
  const btn=$('#bonusBtn'),msg=$('#bonusMsg');const played=localStorage.getItem('fomo:played:'+(acct||'').toLowerCase())||localStorage.getItem('fomo:played:any');
  if(S.addon&&S.addon>0n){btn.disabled=true;btn.textContent='Bonus claimed';msg.innerHTML=`You got <b>${ADDON[S.addon]}</b> · <a target="_blank" href="${nftLink(n,S.addon)}">view NFT</a>`}
  else if(S.target&&S.target>0n){btn.disabled=false;btn.textContent='Reveal my add-on';msg.textContent='Your slot is reserved. Reveal to draw the rarity.'}
  else if(!acct){btn.disabled=false;btn.textContent='Connect to claim';msg.textContent=''}
  else if(!played){btn.disabled=true;btn.textContent='Play a free round first';msg.textContent=''}
  else if(S.bonusLeft===0n){btn.disabled=true;btn.textContent='All bonuses claimed'}
  else {btn.disabled=false;btn.textContent='Claim free bonus';msg.textContent='Gas only. No purchase needed.'}}
 // on-chain collection
 const g=$('#chainGrid');if(g){if(acct&&S.ready){const tot=Object.values(S.bal).reduce((a,b)=>a+b,0n);$('#chainMeta').innerHTML=`${tot} on-chain items in <span class="addr">${short(acct)}</span> on ${n.name}`;
   g.innerHTML=[1,2,3,4,5,6,7].map(t=>nftHTML(t,Number(S.bal[t]||0n),S.bal[t]?'':'locked')).join('')+[101,102,103,104].filter(i=>S.bal[i]>0n).map(i=>`<div class="nft" style="--t1:#ffc531;--t2:#c04bff"><div style="aspect-ratio:36/38;display:grid;place-items:center;font-size:40px">✦</div><div class="lb"><b>ADD-ON</b> ${ADDON[i].toUpperCase()}</div></div>`).join('')}
  else{$('#chainMeta').textContent='Connect a wallet to see cards you own on-chain.';g.innerHTML=''}}
 // on-chain evolve
 const ev=$('#evoChain');if(ev){if(acct&&S.ready){ev.innerHTML=[1,2,3,4,5,6].map(t=>{const b=Number(S.bal[t]||0n);return `<div class="shopitem"><div class="info"><b>${t}★ ${TIERS[t].n}</b> ×${b}<br><span class="muted" style="font-size:12px">3 → 1× ${t+1}★ ${TIERS[t+1].n}</span></div><button class="btn sm evb" data-t="${t}" ${b>=3?'':'disabled'} style="width:auto;padding:8px 10px">Evolve</button></div>`}).join('');
   ev.querySelectorAll('.evb').forEach(b=>b.onclick=()=>evolveChain(+b.dataset.t))}else ev.innerHTML=''}
}
async function gasNote(bp,est){try{const f=await bp.getFeeData();const w=est*(f.maxFeePerGas||f.gasPrice||0n);return `≈ ${Number(ethers.formatEther(w)).toFixed(7)} ETH network gas`}catch(e){return 'plus network gas'}}
function receipt(title,n,tx,id,extra=''){modal(`<h2 class="center">${title}</h2>${id<=7?`<div style="width:60%;margin:10px auto">${nftHTML(id)}</div>`:''}<p class="center">${extra}</p><div class="row" style="margin-top:12px"><a class="btn sm" style="text-align:center;text-decoration:none" target="_blank" href="${n.exp}/tx/${tx}">Transaction</a><a class="btn sm" style="text-align:center;text-decoration:none" target="_blank" href="${nftLink(n,id)}">View NFT</a></div><button class="btn sm ghost" style="margin-top:10px" onclick="closeModal()">Close</button>`)}
window.mintCard=async(t)=>{let ctx;try{ctx=await signerC()}catch(e){return}const {c,bp,n}=ctx;const price=S.prices[t]??await c.priceOf(t);
 try{const est=await c.mint.estimateGas(t,1,{value:price});const g=await gasNote(bp,est);
  modal(`<h2 class="center">Confirm mint</h2><div style="width:50%;margin:10px auto">${nftHTML(t)}</div><p class="center"><b>${t}★ ${TIERS[t].name}</b><br>Price ${fmt(price)} ${n.main?'ETH':'test ETH'} (fixed in contract)<br><span class="muted">${g} · no other fees</span></p><div class="row" style="margin-top:12px"><button class="btn sm ghost" onclick="closeModal()">Cancel</button><button class="btn sm" id="goMint">Mint</button></div>`);
  $('#goMint').onclick=async()=>{closeModal();try{toast('Confirm in your wallet…');const tx=await c.mint(t,1,{value:price,gasLimit:est*12n/10n});toast('Minting…');const r=await tx.wait();if(r.status!==1)throw new Error('reverted');
   await load();receipt('Minted!',n,tx.hash,t,`${t}★ ${TIERS[t].name} is in your wallet.<br>Paid ${fmt(price)} ${n.main?'ETH':'test ETH'}.`)}catch(e){toast('Mint cancelled or failed. Nothing was charged except any gas used.')}}
 }catch(e){toast(e.shortMessage&&/insufficient/i.test(e.shortMessage)?'Not enough ETH for price + gas':'Mint unavailable: '+(e.shortMessage||'check wallet'))}};
async function evolveChain(t){let ctx;try{ctx=await signerC()}catch(e){return}const {c,n}=ctx;try{toast('Confirm in your wallet…');const tx=await c.evolve(t,1);toast('Evolving…');await tx.wait();await load();receipt('Evolved!',n,tx.hash,t+1,`3× ${t}★ → 1× ${t+1}★ ${TIERS[t+1].name}`)}catch(e){toast('Evolve cancelled or failed')}}
async function bonus(){if(!acct){openConnect();return}let ctx;try{ctx=await signerC()}catch(e){return}const {c,bp,n}=ctx;
 try{if(!(S.target>0n)){toast('Confirm claim in your wallet (gas only)…');const tx=await c.claimBonus();await tx.wait();await load()}
  $('#bonusMsg').textContent='Drawing rarity from a future block…';const tgt=S.target;for(let i=0;i<30;i++){const bn=await bp.getBlockNumber();if(BigInt(bn)>tgt)break;await new Promise(r=>setTimeout(r,1500))}
  toast('Confirm reveal in your wallet (gas only)…');const tx2=await c.revealBonus(acct);await tx2.wait();await load();
  if(S.addon>0n)modal(`<h2 class="center">Early Adopter Bonus</h2><div style="font-size:64px;text-align:center;color:var(--g)">✦</div><p class="center"><b>${ADDON[S.addon]}</b></p><p class="muted center">Rarity drawn on-chain from block ${tgt}.</p><div class="row" style="margin-top:12px"><a class="btn sm" style="text-align:center;text-decoration:none" target="_blank" href="${n.exp}/tx/${tx2.hash}">Transaction</a><a class="btn sm" style="text-align:center;text-decoration:none" target="_blank" href="${nftLink(n,S.addon)}">View NFT</a></div><button class="btn sm ghost" style="margin-top:10px" onclick="closeModal()">Close</button>`);
 }catch(e){toast('Bonus cancelled or failed');await load()}}
$('#bonusBtn')&&($('#bonusBtn').onclick=bonus);
window.chainUI={render,load};
let last=null;setInterval(()=>{if(net()&&acct!==last){last=acct;load()}},1500);setInterval(()=>net()&&load(),30000);
