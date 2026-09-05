package com.digitalstables.paula.uploader;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.util.Map;

import org.apache.commons.io.FileUtils;
import com.fazecast.jSerialComm.SerialPort;

// Flashes a downloaded firmware binary onto whatever ESP32 device is plugged into the Pi,
// mirroring the factory webapp's UploadFirmwareProcessingHandler exactly (same esptool
// invocation, same flash offsets, same port auto-detect pattern) and
// ReUploadFirmwareProcessingHandler's post-flash Ping/GetIpAddress sanity check. Reimplemented
// here (rather than reused) because this is a separate deployable project running on the Pi, not
// the NUC - the Pi needs its own local install of the esp32 Arduino core toolchain at the same
// path convention for this to work.
public class FirmwareFlasher {

	private static final String ESPTOOL_PATH = "/home/pi/.arduino15/packages/esp32/tools/esptool_py/3.0.0/esptool.py";
	private static final String BOOT_APP0_PATH = "/home/pi/.arduino15/packages/esp32/hardware/esp32/1.0.6/tools/partitions/boot_app0.bin";
	private static final String BOOTLOADER_PATH = "/home/pi/.arduino15/packages/esp32/hardware/esp32/1.0.6/tools/sdk/bin/bootloader_dio_80m.bin";
	// Pinned deliberately, do not "helpfully" bump this. Confirmed at the bench (both
	// apt-installed and freshly pip-installed) that esptool 4.7.0 silently wipes this board's
	// entire NVS partition (device name, CSW calibration, everything) on every flash, even
	// restricted to these same four offsets. esptool 3.0.0 does not have this problem.

	private static final int DATA_RATE = 115200;
	private static final int READ_TIMEOUT_MILLISECONDS = 500;
	private static final int MAX_WAIT_MILLISECONDS = 30000;

	// Two-device setup (a separate Paula/Wally controller plus the target device): any
	// ttyUSB*/ttyACM* port that isn't Wally's CP2104 is assumed to be the target.
	public SerialPort findTargetPort() {
		return findTargetPort(true);
	}

	// excludeWallyPort=false is for the single-device field scenario - Pi 3B with one USB cable
	// into one Wally board, which IS the target, no separate controller plugged in at all. With
	// exclusion left on in that setup, findWallyPort() matches that same Wally's CP2104 (Wally's
	// own carrier board uses one too, confirmed against its KiCad schematic) and excludes the
	// only port present, leaving nothing to flash - this parameter is the fix. Main.flashDirect()
	// calls this with false; the two-device flash()/watch-flash path keeps the old exclude-Wally
	// behavior via the no-arg overload above.
	public SerialPort findTargetPort(boolean excludeWallyPort) {
		java.util.List<String> candidateNames = new java.util.ArrayList<>();
		for (SerialPort port : SerialPort.getCommPorts()) {
			String name = port.getSystemPortName();
			if (name.startsWith("ttyUSB") || name.startsWith("ttyACM")) {
				candidateNames.add(name);
			}
		}
		// Defensive backstop for the exact single-device scenario the comment above already
		// documents (confirmed again 2026-09-05 on PaulaDeployer, which always called this with
		// excludeWallyPort=true and had no per-caller override): if there's only one serial
		// candidate plugged in at all, it can't simultaneously be "the target minus Wally", so
		// skip the probe regardless of what the caller passed - probing here means opening/
		// writing to the target itself, which resets it and can corrupt the next command sent.
		SerialPort wally = (excludeWallyPort && candidateNames.size() > 1) ? PaulaSerialLink.findWallyPort() : null;
		for (SerialPort port : SerialPort.getCommPorts()) {
			String name = port.getSystemPortName();
			if (wally != null && name.equals(wally.getSystemPortName())) {
				continue;
			}
			if (candidateNames.contains(name)) {
				return port;
			}
		}
		return null;
	}

	public boolean flash(String binPath, String partitionsPath, String workDir) throws IOException, InterruptedException {
		return flash(binPath, partitionsPath, workDir, true);
	}

	public boolean flash(String binPath, String partitionsPath, String workDir, boolean excludeWallyPort) throws IOException, InterruptedException {
		SerialPort targetPort = findTargetPort(excludeWallyPort);
		if (targetPort == null) {
			System.out.println("No target device found - is it plugged in?");
			return false;
		}
		String portName = "/dev/" + targetPort.getSystemPortName();

		StringBuffer command = new StringBuffer();
		command.append("#!/bin/bash" + System.lineSeparator());
		command.append("python \"" + ESPTOOL_PATH + "\" ");
		command.append("--chip esp32 --port \"" + portName + "\" --baud 921600 --before default_reset ");
		command.append("--after hard_reset write_flash -z --flash_mode dio --flash_freq 80m ");
		command.append("--flash_size detect 0xe000 ");
		command.append("\"" + BOOT_APP0_PATH + "\" ");
		command.append("0x1000 \"" + BOOTLOADER_PATH + "\" ");
		command.append("0x10000 \"" + binPath + "\" ");
		command.append("0x8000 \"" + partitionsPath + "\"" + System.lineSeparator());
		command.append("touch firmwareUploadComplete");

		File uploadFile = new File(workDir, "upload.sh");
		FileUtils.writeStringToFile(uploadFile, command.toString());
		uploadFile.setExecutable(true);

		ProcessBuilder pb = new ProcessBuilder(uploadFile.getAbsolutePath());
		pb.directory(new File(workDir));
		pb.redirectErrorStream(true);
		Process p = pb.start();

		BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
		String line;
		while ((line = reader.readLine()) != null) {
			System.out.println("esptool: " + line);
			if (line.startsWith("Serial port")) {
				System.out.println("*** PRESS PROGRAM NOW ***");
				PiStatusLed.blinkForProgramPrompt();
			} else if (line.startsWith("Hard resetting via RTS")) {
				System.out.println("*** PRESS RESET NOW ***");
				PiStatusLed.blinkForResetPrompt();
				Thread.sleep(5000);
			}
		}
		reader.close();

		int exitCode = p.waitFor();
		File completeFile = new File(workDir, "firmwareUploadComplete");
		return exitCode == 0 && completeFile.isFile();
	}

	// Same bounded-poll send/wait-for-Ok-or-Failure pattern as PaulaSerialLink, pointed at the
	// just-flashed device instead of Wally.
	public String pingTarget() {
		return pingTarget(true);
	}

	public String pingTarget(boolean excludeWallyPort) {
		SerialPort port = findTargetPort(excludeWallyPort);
		if (port == null) return null;
		return sendCommand(port, "Ping");
	}

	public String getTargetIpAddress() {
		return getTargetIpAddress(true);
	}

	public String getTargetIpAddress(boolean excludeWallyPort) {
		SerialPort port = findTargetPort(excludeWallyPort);
		if (port == null) return null;
		return sendCommand(port, "GetIpAddress");
	}

	private String sendCommand(SerialPort port, String command) {
		port.setComPortParameters(DATA_RATE, 8, SerialPort.ONE_STOP_BIT, SerialPort.NO_PARITY);
		port.setComPortTimeouts(SerialPort.TIMEOUT_READ_SEMI_BLOCKING, READ_TIMEOUT_MILLISECONDS, 0);
		if (!port.openPort()) return null;

		BufferedReader input = new BufferedReader(new InputStreamReader(port.getInputStream()));
		BufferedWriter output = new BufferedWriter(new OutputStreamWriter(port.getOutputStream()));
		try {
			output.write(command, 0, command.length());
			Thread.sleep(100);
			output.flush();

			long deadline = System.currentTimeMillis() + MAX_WAIT_MILLISECONDS;
			while (System.currentTimeMillis() < deadline) {
				if (input.ready()) {
					String line = input.readLine();
					if (line != null && (line.contains("Ok") || line.contains("Failure"))) {
						return line;
					}
				}
				Thread.sleep(200);
			}
			return null;
		} catch (IOException | InterruptedException e) {
			System.out.println("Error talking to target device: " + e.getMessage());
			return null;
		} finally {
			try { input.close(); } catch (IOException e) { /* ignore */ }
			try { output.close(); } catch (IOException e) { /* ignore */ }
			port.closePort();
		}
	}
}
