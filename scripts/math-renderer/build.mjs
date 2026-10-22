// Build-time only. App rendering uses JavaScriptCore, without Node or network APIs.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import crypto from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const toolchain=path.resolve(process.argv[2]||path.dirname(fileURLToPath(import.meta.url)));
const esbuild=await import(pathToFileURL(path.join(toolchain,'node_modules/esbuild/lib/main.js')));
const output=path.join(root,'Resources/CaptureMath/mathjax-4.1.3.bundle.js');
const result=await esbuild.build({entryPoints:[path.join(root,'scripts/math-renderer/entry.js')],nodePaths:[path.join(toolchain,'node_modules')],bundle:true,platform:'browser',target:'es2022',format:'iife',globalName:'ThermoMath',minify:true,legalComments:'eof',outfile:output,metafile:true});
const sourcePackages=new Set();
for(const input of Object.keys(result.metafile.inputs)) { const m=input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)/);if(m)sourcePackages.add(m[1]) }
const deps={};
for(const name of [...sourcePackages].sort()) { const p=JSON.parse(fs.readFileSync(path.join(toolchain,'node_modules',name,'package.json')));deps[name]={version:p.version,license:p.license} }
const bytes=fs.readFileSync(output);
fs.writeFileSync(path.join(root,'Resources/CaptureMath/provenance.json'),JSON.stringify({mathjax:'4.1.3',font:'mathjax-tex',entrySHA256:crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'scripts/math-renderer/entry.js'))).digest('hex'),lockSHA256:crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'scripts/math-renderer/package-lock.json'))).digest('hex'),sha256:crypto.createHash('sha256').update(bytes).digest('hex'),bytes:bytes.length,dependencies:deps,packages:['base','ams','newcommand','amscd','bbox','boldsymbol','braket','cancel','cases','color','enclose','extpfeil','mathtools','mhchem','physics','textcomp','textmacros','unicode','units','upgreek','verb']},null,2)+'\n');
console.log('Built',bytes.length,'bytes',deps);
