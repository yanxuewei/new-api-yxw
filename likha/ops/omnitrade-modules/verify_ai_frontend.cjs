const fs=require('fs');
const path=require('path');
const assert=require('assert');
const workspace='C:/Users/pc260829/.workbuddy/binaries/node/workspace/omnitrade-web';
const {parse,compileScript,compileTemplate}=require(path.join(workspace,'node_modules/@vue/compiler-sfc'));
const root=path.join(__dirname,'erp-web/src/views/ai');
for(const name of ['Assistant','Pricing','Recommend','Anomaly','Description','InventoryPredict']){
 const file=path.join(root,name+'.vue');const source=fs.readFileSync(file,'utf8');
 assert(!/Math\.random\s*\(/.test(source),name+' contains randomized business data');
 assert(!/SKU-BLU|SKU-STN|330\+|callMock|mockDescriptions/.test(source),name+' contains old sample business results');
 const parsed=parse(source,{filename:file});assert.equal(parsed.errors.length,0,JSON.stringify(parsed.errors));
 const script=compileScript(parsed.descriptor,{id:'ai-'+name});
 const template=compileTemplate({source:parsed.descriptor.template.content,filename:file,id:'ai-'+name,compilerOptions:{bindingMetadata:script.bindings}});
 assert.equal(template.errors.length,0,JSON.stringify(template.errors));
 assert(!source.includes('v-html'),name+' renders untrusted generated HTML');
 console.log('PASS_AI_SFC',name);
}
const api=fs.readFileSync(path.join(__dirname,'erp-web/src/api/ai.ts'),'utf8');
assert(api.includes('/ai-center'));
assert(/interface AnomalyOrder\s*\{\s*id:\s*string/.test(api),'Order IDs must remain strings');
assert(api.includes('expectedRuleKey'),'Confirmation must include rule concurrency token');
const description=fs.readFileSync(path.join(root,'Description.vue'),'utf8');
assert(description.includes('allow-create'),'SKU outside first 500 must be enterable');
assert(!description.includes('some(product => product.sku === form.sku)'),'Reload must retain manually entered SKU');
for(const name of ['Pricing','Recommend','Anomaly','InventoryPredict']) {
 const source=fs.readFileSync(path.join(root,name+'.vue'),'utf8');
 assert(source.includes('offset: (page.value - 1) * 100'),name+' must use server pagination');
}
console.log('AI_FRONTEND_STATIC_ACCEPTANCE_OK (not browser E2E)');
