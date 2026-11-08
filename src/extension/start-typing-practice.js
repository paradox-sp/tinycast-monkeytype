"use strict";

const { environment, showToast, Toast } = require("@raycast/api");
const { execFile } = require("child_process");
const { join, isAbsolute, dirname, basename } = require("path");
const { existsSync } = require("fs");

module.exports = async function startTypingPractice() {
  try {
    const assetsPath = environment.assetsPath;
    if (typeof assetsPath !== "string" || !isAbsolute(assetsPath)) {
      throw new Error("Tinycast did not provide an absolute extension assets directory.");
    }
    const appPath = join(assetsPath, "monkeytype-unoffical.app");
    if (!existsSync(join(appPath, "Contents", "MacOS", "monkeytype-unoffical"))) {
      throw new Error("The monkeytype-unoffical helper is missing. Reinstall the extension.");
    }
    const supportPath = environment.supportPath;
    if (typeof supportPath !== "string" || !isAbsolute(supportPath)) {
      throw new Error("Tinycast did not provide an absolute extension support directory.");
    }
    const host = basename(dirname(dirname(supportPath)));
    if (basename(dirname(supportPath)) !== "extension-support" ||
        !["com.tinycast.app", "com.tinycast.app.beta", "com.tinycast.app.dev"].includes(host)) {
      throw new Error("Could not identify Tinycast’s appearance preference domain.");
    }
    const args = ["-a", appPath, `monkeytype-unoffical://open?host=${host}`];
    // Await Launch Services before Tinycast releases this command's JavaScript context.
    await new Promise((resolve, reject) => {
      execFile("/usr/bin/open", args, { timeout: 15000 }, (error, _stdout, stderr) => {
        if (error) reject(new Error(`Could not open monkeytype-unoffical: ${String(stderr || error.message).trim()}`));
        else resolve();
      });
    });
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: "Could not start monkeytype-unoffical", message: error.message });
    throw error;
  }
};
