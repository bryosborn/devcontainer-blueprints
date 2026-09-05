const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vscode = require('vscode');

exports.run = async () => {
  const workspace = vscode.workspace.workspaceFolders?.[0];
  assert.ok(workspace, 'The fixture workspace must be open in VS Code');
  const expected = JSON.parse(fs.readFileSync(path.join(workspace.uri.fsPath, 'vscode-expected.json')));
  const resultFile = path.join(workspace.uri.fsPath, 'vscode-result.json');
  const evidence = {
    remoteName: vscode.env.remoteName,
    workspace: workspace.uri.toString(),
    vscodeVersion: vscode.version,
    user: os.userInfo(),
    task: 'Wolfi: Playwright visual acceptance',
  };
  try {
    assert.equal(vscode.env.remoteName, 'dev-container', 'Expected a real Dev Containers extension host');
    assert.equal(vscode.version, expected.vscodeVersion);
    assert.match(fs.readFileSync('/etc/os-release', 'utf8'), /^ID=wolfi$/m);
    assert.equal(evidence.user.username, expected.user);
    assert.equal(evidence.user.uid, expected.uid);
    assert.equal(evidence.user.gid, expected.gid);
    const cache = path.join(os.homedir(), '.cache');
    fs.mkdirSync(cache, { recursive: true });
    const cacheProbe = fs.mkdtempSync(path.join(cache, 'wolfi-playwright-'));
    fs.writeFileSync(path.join(cacheProbe, 'write-test'), 'writable');
    fs.rmSync(cacheProbe, { recursive: true });
    const manifest = fs.readFileSync('/opt/playwright/manifest.json', 'utf8');
    assert.equal(require('node:crypto').createHash('sha256').update(manifest).digest('hex'),
      expected.playwrightManifestSha256);
    await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(
      vscode.Uri.joinPath(workspace.uri, 'visual.spec.cjs')));
    const task = (await vscode.tasks.fetchTasks()).find(item => item.name === evidence.task);
    assert.ok(task, 'VS Code must discover the real workspace task');
    const completion = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { subscription.dispose(); reject(new Error('VS Code task timed out')); }, 300000);
      const subscription = vscode.tasks.onDidEndTaskProcess(event => {
        if (event.execution.task.name !== evidence.task) return;
        clearTimeout(timer);
        subscription.dispose();
        resolve(event.exitCode);
      });
    });
    await vscode.tasks.executeTask(task);
    evidence.taskExitCode = await completion;
    assert.equal(evidence.taskExitCode, 0, 'The task must complete successfully');
    const output = fs.readFileSync(path.join(workspace.uri.fsPath, 'vscode-task.log'), 'utf8');
    assert.match(output, /TOOLBOX_PLAYWRIGHT_FIXTURE_PASS/);
    for (const file of ['desktop-initial.png', 'desktop.png', 'mobile.png', 'report.json']) {
      assert.ok(fs.statSync(path.join(workspace.uri.fsPath, 'results', file)).size > 0, `Missing ${file}`);
    }
    const report = JSON.parse(fs.readFileSync(path.join(workspace.uri.fsPath, 'results/report.json')));
    assert.equal(report.stats.expected, 2);
    for (const key of ['unexpected', 'flaky', 'skipped']) assert.equal(report.stats[key], 0);
    assert.deepEqual(report.errors, []);
    evidence.testCounts = report.stats;
    evidence.status = 'PASS';
    fs.writeFileSync(resultFile, JSON.stringify(evidence, null, 2) + '\n');
    console.log('TOOLBOX_VSCODE_PLAYWRIGHT_PASS');
  } catch (error) {
    evidence.status = 'FAIL';
    evidence.error = error.stack || String(error);
    fs.writeFileSync(resultFile, JSON.stringify(evidence, null, 2) + '\n');
    throw error;
  }
};
