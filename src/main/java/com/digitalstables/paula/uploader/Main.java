package com.digitalstables.paula.uploader;

import java.io.File;
import org.json.JSONArray;
import org.json.JSONObject;

// CLI entry point for the bridge tool. sync-pull and sync-push are manually-run commands over
// SSH while the Pi is on the office network. flash/watch-flash happen in the field, where the Pi
// has no network at all (deliberate - farm WiFi can't be trusted) and so no SSH access either -
// watch-flash is what makes the field step possible without a laptop: start it over SSH before
// leaving the office (it keeps running in the background after you disconnect), then in the
// field the only trigger available is Paula's one working slide switch.
//
//   sync-pull [nucBaseUrl]  - run at the office before heading out
//   flash                   - flashes immediately, no gesture wait (bench testing over SSH)
//   watch-flash [timeoutMinutes] - run before leaving the office (nohup'd); blocks until the
//                             switch is flipped away from its start position and back again in
//                             the field, then flashes. Default timeout 240 minutes.
//   flash-direct            - single-device mode: Pi 3B + one USB cable into one Wally board,
//                             which IS the target being upgraded - no separate Paula controller,
//                             no OLED, no switch gesture. Skips PaulaSerialLink entirely (nothing
//                             to talk to) and does not exclude Wally's own CP2104 port when
//                             looking for the target, unlike flash/watch-flash which assume a
//                             second, separate device is present. Run this directly over SSH once
//                             the device is plugged in; "press PROGRAM/RESET now" prompts are
//                             signalled on the Pi's onboard LED as well as stdout, for when nobody
//                             is watching the SSH session at that exact moment.
//   diagnose-ports          - bench-verification: lists every serial port the OS sees, flags
//                             CP2104 candidates, probes each with GetSwitchState, and reports
//                             which one (if any) resolves as Paula. No job/network needed - just
//                             exercises PaulaSerialLink.findWallyPort()'s disambiguation directly.
//   sync-push [nucBaseUrl]  - run back at the office
//
// Default nucBaseUrl is http://factoryserver.local
public class Main {

	private static final String DEFAULT_NUC_BASE_URL = "http://factoryserver.local";
	private static final String WORK_DIR = System.getProperty("user.home") + "/paulauploader-work";
	private static final int DEFAULT_WATCH_TIMEOUT_MINUTES = 240;

	public static void main(String[] args) throws Exception {
		if (args.length == 0) {
			System.out.println("Usage: paulauploader <sync-pull|flash|watch-flash|flash-direct|diagnose-ports|sync-push> [arg]");
			return;
		}

		String command = args[0];

		switch (command) {
			case "sync-pull":
				syncPull(args.length > 1 ? args[1] : DEFAULT_NUC_BASE_URL);
				break;
			case "flash":
				flash();
				break;
			case "watch-flash":
				int timeoutMinutes = args.length > 1 ? Integer.parseInt(args[1]) : DEFAULT_WATCH_TIMEOUT_MINUTES;
				watchFlash(timeoutMinutes);
				break;
			case "flash-direct":
				flashDirect();
				break;
			case "diagnose-ports":
				PaulaSerialLink.diagnosePorts();
				break;
			case "sync-push":
				syncPush(args.length > 1 ? args[1] : DEFAULT_NUC_BASE_URL);
				break;
			default:
				System.out.println("Unknown command: " + command);
				System.out.println("Usage: paulauploader <sync-pull|flash|watch-flash|flash-direct|diagnose-ports|sync-push> [arg]");
		}
	}

	private static void syncPull(String nucBaseUrl) throws Exception {
		FactorySyncClient client = new FactorySyncClient(nucBaseUrl);
		DeploymentStore store = new DeploymentStore();
		PaulaSerialLink paula = new PaulaSerialLink();

		JSONArray pending = client.pullPendingDeployments();
		if (pending.length() == 0) {
			System.out.println("Nothing pending - nothing to do.");
			paula.setStatusText("No pending deployments");
			return;
		}

		// One job at a time by operational rule - always take the oldest pending item.
		JSONObject job = pending.getJSONObject(0);
		String repositoryName = job.getString("firmwarerepositoryName");

		JSONArray firmwareList = client.pullLatestFirmwareList();
		JSONObject firmware = null;
		for (int i = 0; i < firmwareList.length(); i++) {
			JSONObject candidate = firmwareList.getJSONObject(i);
			if (candidate.getString("repositoryName").equals(repositoryName)) {
				firmware = candidate;
				break;
			}
		}
		if (firmware == null) {
			System.out.println("No firmware found for repo " + repositoryName);
			return;
		}

		int firmwareId = firmware.getInt("id");
		int version = firmware.getInt("version");

		File jobDir = new File(WORK_DIR, repositoryName + "_v" + version);
		jobDir.mkdirs();
		String binPath = new File(jobDir, repositoryName + ".ino.bin").getAbsolutePath();
		String partitionsPath = new File(jobDir, repositoryName + ".ino.partitions.bin").getAbsolutePath();

		System.out.println("Downloading " + repositoryName + " v" + version + "...");
		client.downloadFirmwareBinary(firmwareId, "bin", binPath);
		client.downloadFirmwareBinary(firmwareId, "partitions", partitionsPath);

		store.saveCurrentJob(job.getInt("deploymentid"), job.getInt("productid"), job.getString("name"),
				job.optString("serialnumber", ""), repositoryName, firmwareId, version, binPath, partitionsPath);

		String status = job.getString("name") + " ready - flip switch out and back to flash";
		System.out.println(status);
		paula.setStatusText(status);
	}

	private static void flash() throws Exception {
		DeploymentStore store = new DeploymentStore();
		PaulaSerialLink paula = new PaulaSerialLink();
		FirmwareFlasher flasher = new FirmwareFlasher();

		JSONObject job = store.getCurrentJob();
		if (job == null) {
			System.out.println("No job loaded - run sync-pull first.");
			return;
		}

		doFlash(job, store, paula, flasher);
	}

	// Blocks with no network needed at all - polls Paula's switch over the USB-serial link only.
	// Meant to be started over SSH before leaving the office (e.g. "nohup java -jar
	// paulauploader.jar watch-flash > watch-flash.log 2>&1 & disown") so it keeps running after
	// the SSH session and the office network connection are both gone. In the field, plug the
	// target device into the Pi's other USB port, then flip Paula's slide switch away from
	// whatever position it's currently in and back again - that round-trip is the trigger, chosen
	// specifically because a single flip changing the resting position wouldn't be distinguishable
	// from someone just bumping the switch.
	private static void watchFlash(int timeoutMinutes) throws Exception {
		DeploymentStore store = new DeploymentStore();
		PaulaSerialLink paula = new PaulaSerialLink();
		FirmwareFlasher flasher = new FirmwareFlasher();

		JSONObject job = store.getCurrentJob();
		if (job == null) {
			System.out.println("No job loaded - run sync-pull first.");
			return;
		}

		Boolean startPosition = paula.isSwitchLeft();
		if (startPosition == null) {
			System.out.println("Could not read Paula's switch - is Wally plugged in?");
			return;
		}
		System.out.println("Watching for the switch to flip away from " + (startPosition ? "Left" : "Right")
				+ " and back again (timeout " + timeoutMinutes + " min)...");

		boolean armed = false;
		long deadline = System.currentTimeMillis() + timeoutMinutes * 60_000L;
		while (System.currentTimeMillis() < deadline) {
			Boolean current = paula.isSwitchLeft();
			if (current != null) {
				if (!armed && !current.equals(startPosition)) {
					armed = true;
					System.out.println("Switch flipped - waiting for it to return...");
				} else if (armed && current.equals(startPosition)) {
					System.out.println("Gesture detected - flashing.");
					doFlash(job, store, paula, flasher);
					return;
				}
			}
			Thread.sleep(500);
		}
		System.out.println("watch-flash timed out after " + timeoutMinutes + " minutes with no gesture detected.");
	}

	private static void doFlash(JSONObject job, DeploymentStore store, PaulaSerialLink paula, FirmwareFlasher flasher) throws Exception {
		System.out.println("Flashing " + job.getString("productname") + "...");
		paula.setStatusText("Flashing " + job.getString("productname") + "...");

		String workDir = new File(job.getString("binpath")).getParent();
		boolean flashOk = flasher.flash(job.getString("binpath"), job.getString("partitionspath"), workDir);

		boolean success = false;
		if (flashOk) {
			String ping = flasher.pingTarget();
			success = ping != null && ping.contains("Ok");
		}

		store.recordResult(job.getInt("deploymentid"), job.getInt("productid"), success,
				job.getInt("firmwareid"), job.getInt("firmwareversion"));

		String status = success
				? job.getString("productname") + " flashed OK - remember to Sync when back at the office"
				: job.getString("productname") + " FAILED - will retry next attempt";
		System.out.println(status);
		paula.setStatusText(status);
	}

	// Single-device mode: Pi 3B + one USB cable into the one Wally board being upgraded, no
	// separate Paula controller. Deliberately does not touch PaulaSerialLink at all - there's
	// nothing to talk to - and passes excludeWallyPort=false through to FirmwareFlasher so the
	// only serial device present (this Wally, on its own CP2104) is treated as the target instead
	// of being mistaken for "the Paula controller" and excluded.
	private static void flashDirect() throws Exception {
		DeploymentStore store = new DeploymentStore();
		FirmwareFlasher flasher = new FirmwareFlasher();

		JSONObject job = store.getCurrentJob();
		if (job == null) {
			System.out.println("No job loaded - run sync-pull first.");
			return;
		}

		System.out.println("Flashing " + job.getString("productname") + " (single-device mode)...");

		String workDir = new File(job.getString("binpath")).getParent();
		boolean flashOk = flasher.flash(job.getString("binpath"), job.getString("partitionspath"), workDir, false);

		boolean success = false;
		if (flashOk) {
			String ping = flasher.pingTarget(false);
			success = ping != null && ping.contains("Ok");
		}

		store.recordResult(job.getInt("deploymentid"), job.getInt("productid"), success,
				job.getInt("firmwareid"), job.getInt("firmwareversion"));

		System.out.println(success
				? job.getString("productname") + " flashed OK - remember to Sync when back at the office"
				: job.getString("productname") + " FAILED - will retry next attempt");
	}

	private static void syncPush(String nucBaseUrl) throws Exception {
		FactorySyncClient client = new FactorySyncClient(nucBaseUrl);
		DeploymentStore store = new DeploymentStore();
		PaulaSerialLink paula = new PaulaSerialLink();

		JSONArray unreported = store.getUnreportedResults();
		if (unreported.length() == 0) {
			System.out.println("Nothing to report.");
			paula.setStatusText("Nothing to report");
			return;
		}

		client.pushResults(unreported);
		for (int i = 0; i < unreported.length(); i++) {
			store.markReported(unreported.getJSONObject(i).getInt("localId"));
		}

		String status = "Reported " + unreported.length() + " result(s) to the factory";
		System.out.println(status);
		paula.setStatusText(status);
	}
}
