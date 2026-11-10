// Creates zellio.config.json (git-ignored) from the example when it is missing. Metro needs the file to exist.
const fs = require('node:fs');
const path = require('node:path');

const target = path.join(__dirname, '..', 'zellio.config.json');
const example = path.join(__dirname, '..', 'zellio.config.example.json');
if (!fs.existsSync(target)) {
  fs.copyFileSync(example, target);
  console.log('Created zellio.config.json. Put your app key in it.');
}
