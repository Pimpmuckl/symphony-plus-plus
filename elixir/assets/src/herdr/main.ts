import { runController } from "./controller";
import { runInspector } from "./inspector";

const entrypoint = process.env.HERDR_PLUGIN_ENTRYPOINT_ID;

(entrypoint === "execution-inspector" ? runInspector() : runController()).catch((error: unknown) => {
  process.stderr.write(`Symphony++ Herdr plugin: ${(error as Error).message}\n`);
  process.exitCode = 1;
});
