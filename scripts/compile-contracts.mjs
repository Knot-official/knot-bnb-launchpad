import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';

const root = process.cwd();
const sourceRoot = path.join(root, 'contracts', 'src');
const sources = {};

function collect(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) collect(absolute);
    else if (entry.name.endsWith('.sol')) {
      const name = path.relative(root, absolute).split(path.sep).join('/');
      sources[name] = { content: fs.readFileSync(absolute, 'utf8') };
    }
  }
}

collect(sourceRoot);

const input = {
  language: 'Solidity',
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    viaIR: true,
    evmVersion: 'cancun',
    outputSelection: { '*': { '*': ['abi'] } },
  },
};

function findImport(name) {
  const candidates = [
    path.join(root, name),
    path.join(root, 'node_modules', name),
  ];
  for (const candidate of candidates)
    if (fs.existsSync(candidate))
      return { contents: fs.readFileSync(candidate, 'utf8') };
  return { error: `Import not found: ${name}` };
}

const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImport }));
const errors = (output.errors ?? []).filter((entry) => entry.severity === 'error');
if (errors.length) {
  for (const error of errors) console.error(error.formattedMessage);
  process.exit(1);
}

const contractCount = Object.values(output.contracts ?? {}).reduce(
  (total, contracts) => total + Object.keys(contracts).length,
  0,
);
console.log(`Compiled ${contractCount} contracts and interfaces with solc ${solc.version()}.`);
