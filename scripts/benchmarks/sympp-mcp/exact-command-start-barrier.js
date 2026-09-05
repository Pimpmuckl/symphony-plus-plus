"use strict";

const fs = require("fs");
const { spawn } = require("child_process");

const [readyFile, releaseFile, workingDirectory, command, ...args] = process.argv.slice(2);
if (!readyFile || !releaseFile || !workingDirectory || !command) process.exit(2);
process.chdir(process.env.SystemRoot || require("os").tmpdir());

let child = null;
const stopChild = () => {
  if (!child) process.exit(1);
  if (child.exitCode === null) child.kill();
};
process.once("SIGTERM", stopChild);
process.once("SIGINT", stopChild);

(async () => {
  fs.writeFileSync(readyFile, "ready\n");
  while (!fs.existsSync(releaseFile)) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }

  child = spawn(command, args, {
    cwd: workingDirectory,
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  process.stdin.pipe(child.stdin);
  child.stdout.pipe(process.stdout);
  child.stderr.pipe(process.stderr);
  child.once("error", (error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
  child.once("close", (code) => {
    process.stdin.unpipe(child.stdin);
    process.stdin.pause();
    process.exitCode = code ?? 1;
  });
})().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
