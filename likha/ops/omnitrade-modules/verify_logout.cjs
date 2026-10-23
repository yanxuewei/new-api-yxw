const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require('C:/Users/pc260829/.workbuddy/binaries/node/workspace/omnitrade-web/node_modules/typescript');
const source = fs.readFileSync(__dirname + '/erp-web/src/layout/index.vue', 'utf8');
assert(source.includes('@command="handleUserCommand"'));
assert(source.includes('command="logout" :disabled="loggingOut"'));
const script = source.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)[1].replace(/^import .*$/gm, '');
const js = ts.transpileModule(script, {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
function setup(post, hasToken = true) {
  const local = new Map([['userInfo', '{}'], ['refreshToken', 'refresh'], ['unrelated', 'preserve']]);
  if (hasToken) local.set('token', 'test-token');
  const session = new Map([['token', 'old'], ['userInfo', '{}'], ['refreshToken', 'old']]);
  const calls = [], messages = [], routes = [];
  const storage = map => ({getItem: k => map.get(k), removeItem: k => map.delete(k)});
  const ctx = { ref: value => ({value}), computed: f => f, useRoute: () => ({path:'/user',meta:{}}),
    useRouter: () => ({replace: async path => routes.push(path)}),
    axios: {post: (...args) => {calls.push(args); return post(...args);}},
    ElMessage: {success: msg => messages.push(['success',msg]), warning: msg => messages.push(['warning',msg])},
    localStorage: storage(local), sessionStorage: storage(session)};
  vm.createContext(ctx);
  vm.runInContext(js + '\nthis.handle = handleUserCommand; this.busy = loggingOut;', ctx);
  return {ctx, local, session, calls, messages, routes};
}
function cleared(t) {
  for (const key of ['token','userInfo','refreshToken']) {
    assert(!t.local.has(key)); assert(!t.session.has(key));
  }
  assert.equal(t.local.get('unrelated'), 'preserve');
  assert.deepEqual(t.routes, ['/login']);
  assert.equal(t.ctx.busy.value, false);
}
(async () => {
  for (const scenario of ['success','business-failure','network-failure','no-token']) {
    const t = setup(async () => {
      if (scenario === 'network-failure') throw Error('timeout');
      return {data: {code: scenario === 'business-failure' ? 500 : 200}};
    }, scenario !== 'no-token');
    await t.ctx.handle('logout'); cleared(t);
    assert.equal(t.messages[0][0], ['success','no-token'].includes(scenario) ? 'success' : 'warning');
    assert.equal(t.calls.length, scenario === 'no-token' ? 0 : 1);
    if (t.calls.length) {
      assert.equal(t.calls[0][0], '/api/auth/logout');
      assert.equal(t.calls[0][2].headers.Authorization, 'Bearer test-token');
      assert.equal(t.calls[0][2].timeout, 10000);
    }
    console.log('PASS', scenario);
  }
  let release;
  const t = setup(() => new Promise(resolve => {release = resolve;}));
  await t.ctx.handle('other'); assert.equal(t.calls.length, 0);
  const first = t.ctx.handle('logout');
  await t.ctx.handle('logout'); assert.equal(t.calls.length, 1); assert(t.ctx.busy.value);
  release({data:{code:200}}); await first; cleared(t);
  console.log('PASS duplicate-click-and-unrelated-command');
  console.log('LOGOUT_FRONTEND_LOGIC_OK (mocked dependencies, not browser test)');
})().catch(error => {console.error(error); process.exitCode = 1;});
