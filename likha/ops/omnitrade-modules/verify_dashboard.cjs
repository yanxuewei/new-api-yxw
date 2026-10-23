const fs = require('fs');
const assert = require('assert/strict');
const {parse} = require('C:/Users/pc260829/.workbuddy/binaries/node/workspace/omnitrade-web/node_modules/@vue/compiler-dom');
const source = fs.readFileSync(__dirname + '/erp-web/src/views/Dashboard.vue', 'utf8');
const template = source.slice(source.indexOf('<template>') + 10, source.indexOf('<script setup'));
const root = parse(template.slice(0, template.lastIndexOf('</template>')));
let statsRow;
function visit(node) {
  if (node.type === 1 && node.tag === 'el-row' && node.props.some(p => p.name === 'class' && p.value?.content === 'stats-row')) statsRow = node;
  for (const child of node.children || []) visit(child);
}
visit(root);
assert(statsRow, 'Missing stats row');
const children = statsRow.children.filter(n => n.type !== 3 && !(n.type === 2 && !n.content.trim()));
assert.equal(children.length, 4, 'Statistics row must have exactly four columns and no stray text');
for (const child of children) {
  assert.equal(child.type, 1);
  assert.equal(child.tag, 'el-col');
  assert(child.props.some(p => p.type === 7 && p.arg?.content === 'span' && p.exp?.content === '6'));
}
console.log('PASS_DASHBOARD_AST: four span=6 columns; no stray text node');
