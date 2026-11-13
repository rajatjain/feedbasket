const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");
const load = createRequire(path.resolve(process.cwd(), "package.json"));
const { Readability } = load("@mozilla/readability");
const { JSDOM } = load("jsdom");

const dom = new JSDOM(fs.readFileSync(0), { url: process.argv[2] });
try {
  const article = new Readability(dom.window.document).parse();
  if (article?.content) process.stdout.write(article.content);
} finally {
  dom.window.close();
}
