import {mathjax} from '@mathjax/src/js/mathjax.js';
import {TeX} from '@mathjax/src/js/input/tex.js';
import {SVG} from '@mathjax/src/js/output/svg.js';
import {liteAdaptor} from '@mathjax/src/js/adaptors/liteAdaptor.js';
import {RegisterHTMLHandler} from '@mathjax/src/js/handlers/html.js';
import {SerializedMmlVisitor} from '@mathjax/src/js/core/MmlTree/SerializedMmlVisitor.js';
import {STATE} from '@mathjax/src/js/core/MathItem.js';
import {MathJaxTexFont} from '@mathjax/mathjax-tex-font/js/svg.js';
import '@mathjax/src/js/input/tex/base/BaseConfiguration.js';
import '@mathjax/src/js/input/tex/ams/AmsConfiguration.js';
import '@mathjax/src/js/input/tex/newcommand/NewcommandConfiguration.js';
import '@mathjax/src/js/input/tex/amscd/AmsCdConfiguration.js';
import '@mathjax/src/js/input/tex/bbox/BboxConfiguration.js';
import '@mathjax/src/js/input/tex/boldsymbol/BoldsymbolConfiguration.js';
import '@mathjax/src/js/input/tex/braket/BraketConfiguration.js';
import '@mathjax/src/js/input/tex/cancel/CancelConfiguration.js';
import '@mathjax/src/js/input/tex/cases/CasesConfiguration.js';
import '@mathjax/src/js/input/tex/color/ColorConfiguration.js';
import '@mathjax/src/js/input/tex/enclose/EncloseConfiguration.js';
import '@mathjax/src/js/input/tex/extpfeil/ExtpfeilConfiguration.js';
import '@mathjax/src/js/input/tex/mathtools/MathtoolsConfiguration.js';
import '@mathjax/src/js/input/tex/mhchem/MhchemConfiguration.js';
import '@mathjax/src/js/input/tex/physics/PhysicsConfiguration.js';
import '@mathjax/src/js/input/tex/textcomp/TextcompConfiguration.js';
import '@mathjax/src/js/input/tex/textmacros/TextMacrosConfiguration.js';
import '@mathjax/src/js/input/tex/unicode/UnicodeConfiguration.js';
import '@mathjax/src/js/input/tex/units/UnitsConfiguration.js';
import '@mathjax/src/js/input/tex/upgreek/UpgreekConfiguration.js';
import '@mathjax/src/js/input/tex/verb/VerbConfiguration.js';

const adaptor=liteAdaptor();
RegisterHTMLHandler(adaptor);
const packages=['base','ams','newcommand','amscd','bbox','boldsymbol','braket','cancel','cases','color','enclose','extpfeil','mathtools','mhchem','physics','textcomp','textmacros','unicode','units','upgreek','verb'];
export function renderJSON(source,display,fontSize,foreground) {
  try {
    if (typeof source!=='string' || !source.trim() || source.length>16384 || !Number.isFinite(fontSize) || fontSize<8 || fontSize>96 || !/^#[0-9a-fA-F]{6}$/.test(foreground)) throw Error('Invalid formula input.');
    // Each call owns its parser and macros. No require/autoload/html/texhtml/setoptions packages.
    const tex=new TeX({packages,maxMacros:1000,maxBuffer:32768,maxTemplateSubtitutions:1000,formatError:(_jax,error)=>{throw Error(error.message)}});
    const svg=new SVG({fontData:MathJaxTexFont,fontCache:'none'});
    const doc=mathjax.document('',{InputJax:tex,OutputJax:svg,renderActions:{removeLatex:[STATE.CONVERT+1,()=>{},math=>math.root.walkTree(node=>{node.attributes.unset('data-latex');node.attributes.unset('data-latex-item')})]}});
    const options={display:!!display,em:fontSize,ex:fontSize*0.442,containerWidth:1200};
    const mml=doc.convert(source,{...options,end:STATE.CONVERT});
    mml.walkTree(node=>{node.attributes.unset('data-latex');node.attributes.unset('data-latex-item')});
    const mathml=new SerializedMmlVisitor().visitTree(mml,doc);
    const node=doc.convert(source,options);
    const element=adaptor.tags(node,'svg')[0];
    if (!element) throw Error('No SVG was produced.');
    const box=adaptor.getAttribute(element,'viewBox').trim().split(/\s+/).map(Number);
    if (box.length!==4 || box.some(v=>!Number.isFinite(v))) throw Error('Invalid SVG geometry.');
    const padding=12,unit=fontSize/1000,width=Math.ceil(box[2]*unit+2*padding),height=Math.ceil(box[3]*unit+2*padding);
    if (width<1 || height<1 || width>8192 || height>8192 || width*height>16000000) throw Error('The formula image is too large.');
    adaptor.setAttribute(element,'width',String(width));adaptor.setAttribute(element,'height',String(height));
    adaptor.setAttribute(element,'viewBox',[box[0]-padding/unit,box[1]-padding/unit,width/unit,height/unit].join(' '));
    adaptor.setAttribute(element,'style','color:'+foreground);
    const output=adaptor.outerHTML(element);
    if (output.length>16*1024*1024 || mathml.length>4*1024*1024) throw Error('The formula output is too large.');
    return JSON.stringify({svg:output,mathml,width,height});
  } catch(error) { return JSON.stringify({error:String(error.message||error).slice(0,2000)}) }
}
