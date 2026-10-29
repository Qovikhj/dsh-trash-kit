// QA helper: parse DSH cordis.patch.yml files and report their structure.
// Locates the `yaml` package at runtime: DSH_YAML_DIR, else the current profile's
// Kept as .cjs on purpose: this folder sits inside a "type": "module" package,
// so a .js file here would be loaded as ESM where require() is unavailable.
// Usage: node check-yaml.cjs <patch.yml> [<patch.yml> ...]
const fs = require('fs');
const os = require('os');
const path = require('path');

function loadYaml() {
  const dir = process.env.DSH_YAML_DIR
    || path.join(os.homedir(), '.dsh', 'profiles', process.env.DSH_PROFILE || 'web', 'node_modules', 'yaml');
  try {
    return require(dir);
  } catch (error) {
    return require('yaml');
  }
}

const YAML = loadYaml();

let bad = 0;
for (const file of process.argv.slice(2)) {
  try {
    const doc = YAML.parse(fs.readFileSync(file, 'utf8'));
    if (!Array.isArray(doc)) throw new Error('top level is not an array');
    const ids = [];
    let guardRow = false;
    for (const entry of doc) {
      if (!entry || typeof entry !== 'object') continue;
      if (Array.isArray(entry.insert)) {
        for (const row of entry.insert) {
          ids.push('insert:' + row.id);
          if (row.id === 'trash-guard') guardRow = true;
        }
      } else if (entry.id) {
        ids.push(entry.id);
      }
    }
    console.log('OK   ' + file);
    console.log('     entries: ' + doc.length + ' -> ' + ids.join(', '));
    console.log('     trash-guard row: ' + (guardRow ? 'present' : 'MISSING'));
  } catch (error) {
    bad += 1;
    console.log('FAIL ' + file + ' -> ' + error.message);
  }
}
process.exit(bad === 0 ? 0 : 1);