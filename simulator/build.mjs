import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const root=new URL('./',import.meta.url),read=p=>readFileSync(new URL(p,root),'utf8');
const identity=JSON.parse(read('identity.json'));const hash=x=>createHash('sha256').update(x).digest('hex');
for(const [p,expected] of Object.entries(identity.files))if(hash(read(p))!==expected)throw Error(`identity/${p}`);
const template=read('page-template.html');if(hash(template)!==identity.templateSha256)throw Error('template identity');
const css=template.match(/<style>\n([\s\S]*?)<\/style>/)[1];
const module=p=>read(p).replace(/^import .*;\n/gm,'').replace(/^export /gm,'');
const js=[module('core.mjs'),module('actions.mjs'),module('properties.mjs'),module('naming.mjs'),`const STORIES=${read('stories.json')};const CORPUS=${read('corpus.json')};const THEOREMS=${read('formal/theorem-debt.json')};const IDENTITY=${read('identity.json')};const NAMINGCORPUS=${read('../lean/naming-corpus.json')};const NAMINGTHEOREMS=${read('../lean/naming-theorem-debt.json')};`,read('template-generic.js'),read('page.mjs')].join('\n');
const html=`<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Singular · A name and its custody</title><style>\n${css}</style><style>\n${read('page.css')}</style></head><body>\n${read('page-body.html')}<script>\n${js.replace(/<\/script/gi,'<\\/script')}\n</script></body></html>\n`;
if(process.argv.includes('--check')){if(read('index.html')!==html)throw Error('page build drift');console.log('PASS page build identity');}else{writeFileSync(new URL('index.html',root),html);console.log(`built simulator/index.html sha256=${hash(html)}`);}
