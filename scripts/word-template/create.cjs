// Build-time template creation with docx-js; the app edits its OOXML at runtime.
const fs=require('fs'),path=require('path');
const {Document,Packer,Paragraph,Math:Equation,MathRun}=require(path.join(process.argv[2],'node_modules/docx'));
const document=new Document({creator:'Thermo',lastModifiedBy:'Thermo',title:'Editable formula',revision:1,styles:{default:{document:{run:{font:'Cambria Math',size:64},paragraph:{spacing:{after:0}}}}},sections:[{properties:{page:{size:{width:11906,height:16838},margin:{top:1440,right:1440,bottom:1440,left:1440}}},children:[new Paragraph({children:[new Equation({children:[new MathRun('THERMO_MATH_SLOT')]})]})]}]});
Packer.toBuffer(document).then(data=>fs.writeFileSync(process.argv[3],data));
