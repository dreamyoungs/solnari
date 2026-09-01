#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const [nodeLicensePath, packageLockPath, nodeModulesPath, swiftCheckoutsPath, outputPath] =
  process.argv.slice(2);

if (
  [nodeLicensePath, packageLockPath, nodeModulesPath, swiftCheckoutsPath, outputPath].some(
    value => value === undefined || value.length === 0,
  )
) {
  process.stderr.write(
    'usage: collect-licenses.mjs <node-license> <package-lock> <node-modules> <swift-checkouts> <output>\n',
  );
  process.exit(64);
}

const divider = '='.repeat(80);
const sections = [
  'Solnari third-party notices',
  '',
  'This distribution includes the following third-party software. License texts are reproduced',
  'for attribution and redistribution compliance; they do not change Solnari\'s Apache-2.0 license.',
];

const appendSection = (title, texts, declaredLicense) => {
  sections.push('', divider, title, divider, '');
  if (declaredLicense !== undefined) sections.push(`Declared license: ${declaredLicense}`, '');
  if (texts.length === 0) {
    sections.push('No standalone license file was present in the installed package.');
    return;
  }
  for (const text of texts) sections.push(text.trim(), '');
};

const licenseTexts = directory => {
  if (!fs.existsSync(directory)) return [];
  return fs
    .readdirSync(directory, {withFileTypes: true})
    .filter(
      entry =>
        entry.isFile() && /^(licen[cs]e|copying|notice)(\.|$)/i.test(entry.name),
    )
    .sort((left, right) => left.name.localeCompare(right.name))
    .map(entry => fs.readFileSync(path.join(directory, entry.name), 'utf8'));
};

appendSection('Node.js runtime', [fs.readFileSync(nodeLicensePath, 'utf8')]);

const packageLock = JSON.parse(fs.readFileSync(packageLockPath, 'utf8'));
const productionPackages = Object.entries(packageLock.packages ?? {})
  .filter(
    ([packagePath, metadata]) =>
      packagePath.startsWith('node_modules/') && metadata.dev !== true,
  )
  .sort(([left], [right]) => left.localeCompare(right));

for (const [packagePath, metadata] of productionPackages) {
  const directory = path.join(nodeModulesPath, packagePath.slice('node_modules/'.length));
  if (!fs.existsSync(directory)) continue;
  const name = metadata.name ?? packagePath.slice('node_modules/'.length);
  const version = metadata.version ?? 'unknown version';
  appendSection(`${name}@${version}`, licenseTexts(directory), metadata.license);
}

if (fs.existsSync(swiftCheckoutsPath)) {
  for (const entry of fs
    .readdirSync(swiftCheckoutsPath, {withFileTypes: true})
    .filter(entry => entry.isDirectory())
    .sort((left, right) => left.name.localeCompare(right.name))) {
    const directory = path.join(swiftCheckoutsPath, entry.name);
    appendSection(`Swift package: ${entry.name}`, licenseTexts(directory));
  }
}

fs.mkdirSync(path.dirname(outputPath), {recursive: true});
fs.writeFileSync(outputPath, `${sections.join('\n').trim()}\n`, {mode: 0o644});
