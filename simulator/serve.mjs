import {createServer} from 'node:http';
import {readFileSync} from 'node:fs';
const server=createServer((req,res)=>{const path=new URL(req.url,'http://localhost').pathname;const filename=path.endsWith('identity.json')?'identity.json':'index.html';res.setHeader('Content-Type',filename.endsWith('json')?'application/json':'text/html; charset=utf-8');res.end(readFileSync(new URL(filename,import.meta.url)));});server.listen(8769,'0.0.0.0',()=>console.log('Singular local preview http://127.0.0.1:8769/simulator/'));
