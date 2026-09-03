package com.digitalstables.paula.uploader;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.util.ArrayList;
import java.util.List;

import com.fazecast.jSerialComm.SerialPort;

// Talks to Paula's ESP32 over the Wally carrier board's onboard CP2104 USB-UART chip. Same
// bounded-poll pattern as the factory webapp's SendOneCommandToSerialPort (rewritten off RXTX
// 2026-07-30 for exactly this reason - a device that never responds must not hang the caller
// forever), reimplemented here because this is a separate deployable project on the Pi, not
// something that can import the factory webapp's classes directly.
public class PaulaSerialLink {

	// Silicon Labs CP2104 - Wally's own carrier board (both Paula's controller AND any
	// Wally-carrier-based target device, e.g. Daffodil-family units) uses this exact chip for its
	// USB-serial link, confirmed against Wally's KiCad schematic. So vendor/product ID alone
	// cannot tell "Paula's controller" apart from "a Wally-carrier target plugged in for
	// flashing" when both are connected at once - findWallyPort() below disambiguates by
	// behavior instead (see its comment).
	private static final int WALLY_VENDOR_ID = 0x10C4;
	private static final int WALLY_PRODUCT_ID = 0xEA60;

	private static final int DATA_RATE = 115200;
	private static final int READ_TIMEOUT_MILLISECONDS = 500;
	private static final int MAX_WAIT_MILLISECONDS = 30000;
	// Short bound for the disambiguation probe below - just needs to see whether a candidate
	// port replies in Paula's shape, not carry out a real command round-trip.
	private static final int PROBE_TIMEOUT_MILLISECONDS = 3000;

	// Cached per-instance so a tight polling loop (watch-flash checks the switch roughly twice a
	// second) doesn't re-probe every candidate CP2104 port on every single call - resolved once,
	// reused until the cached port disappears from the OS's port list (unplugged) or a command on
	// it times out, either of which clears the cache so the next call re-resolves.
	private SerialPort cachedWallyPort;

	// Gathers every CP2104 candidate and probes each with GetSwitchState (Paula-specific - a
	// generic Daffodil/Wally target running product firmware won't recognize it and won't reply
	// with the "Left=...#Right=...#Sleep=..." data line Paula's firmware sends). Whichever
	// candidate answers in that shape is treated as Paula; any other CP2104 port is left alone
	// for FirmwareFlasher to consider as a possible target instead of being blanket-excluded.
	public static SerialPort findWallyPort() {
		List<SerialPort> candidates = new ArrayList<SerialPort>();
		for (SerialPort port : SerialPort.getCommPorts()) {
			if (port.getVendorID() == WALLY_VENDOR_ID && port.getProductID() == WALLY_PRODUCT_ID) {
				candidates.add(port);
			}
		}
		for (SerialPort candidate : candidates) {
			if (probeForPaula(candidate)) {
				return candidate;
			}
		}
		return null;
	}

	private static boolean probeForPaula(SerialPort port) {
		String response = sendCommandOnPort(port, "GetSwitchState", PROBE_TIMEOUT_MILLISECONDS);
		return response != null && response.contains("Left=") && response.contains("Right=");
	}

	// Sends SetStatusText#<text> to Paula's OLED and waits for Ok/Failure. Returns the response
	// line, or null if Wally isn't plugged in / the ESP32 never replied.
	public String setStatusText(String text) {
		return sendCommand("SetStatusText#" + text);
	}

	// Reads the switch position. Paula's GetSwitchState command replies with a data line
	// ("Left=1#Right=0#Sleep=1") followed by "Ok-GetSwitchState" - the same two-line
	// data-then-acknowledgement convention Paula already uses for GetSecret. Returns true if the
	// switch is currently in the Left position, false if Right, null if Wally didn't respond.
	public Boolean isSwitchLeft() {
		String response = sendCommand("GetSwitchState");
		if (response == null) return null;
		for (String line : response.split("\n")) {
			if (line.contains("Left=")) {
				String leftValue = line.substring(line.indexOf("Left=") + 5, line.indexOf("Left=") + 6);
				return "1".equals(leftValue);
			}
		}
		return null;
	}

	// Sends a command to the (cached, disambiguated) Wally port and returns every line Paula
	// replied with (data line(s) plus the final Ok/Failure acknowledgement), newline-joined -
	// callers that only care about the acknowledgement can just check the result contains "Ok",
	// but commands like GetSwitchState that reply with a data line before the acknowledgement
	// need the whole transcript, not just the last line.
	public String sendCommand(String command) {
		SerialPort port = resolveWallyPort();
		if (port == null) {
			System.out.println("Wally not found on any USB port - is it plugged in?");
			return null;
		}
		String result = sendCommandOnPort(port, command, MAX_WAIT_MILLISECONDS);
		if (result == null) {
			// Could mean the device was power-cycled or swapped - drop the cache so the next
			// call re-probes rather than keep trusting a port that just went quiet.
			cachedWallyPort = null;
		}
		return result;
	}

	private SerialPort resolveWallyPort() {
		if (cachedWallyPort != null) {
			for (SerialPort port : SerialPort.getCommPorts()) {
				if (port.getSystemPortName().equals(cachedWallyPort.getSystemPortName())) {
					return cachedWallyPort;
				}
			}
			cachedWallyPort = null; // no longer enumerated - unplugged, re-resolve below
		}
		cachedWallyPort = findWallyPort();
		return cachedWallyPort;
	}

	private static String sendCommandOnPort(SerialPort port, String command, int timeoutMillis) {
		port.setComPortParameters(DATA_RATE, 8, SerialPort.ONE_STOP_BIT, SerialPort.NO_PARITY);
		port.setComPortTimeouts(SerialPort.TIMEOUT_READ_SEMI_BLOCKING, READ_TIMEOUT_MILLISECONDS, 0);

		if (!port.openPort()) {
			return null;
		}

		BufferedReader input = new BufferedReader(new InputStreamReader(port.getInputStream()));
		BufferedWriter output = new BufferedWriter(new OutputStreamWriter(port.getOutputStream()));
		try {
			output.write(command, 0, command.length());
			Thread.sleep(100);
			output.flush();

			StringBuilder transcript = new StringBuilder();
			long deadline = System.currentTimeMillis() + timeoutMillis;
			while (System.currentTimeMillis() < deadline) {
				if (input.ready()) {
					String line = input.readLine();
					if (line != null) {
						if (transcript.length() > 0) transcript.append("\n");
						transcript.append(line);
						if (line.contains("Ok") || line.contains("Failure")) {
							return transcript.toString();
						}
					}
				}
				Thread.sleep(100);
			}
			return null;
		} catch (IOException | InterruptedException e) {
			return null;
		} finally {
			try { input.close(); } catch (IOException e) { /* ignore */ }
			try { output.close(); } catch (IOException e) { /* ignore */ }
			port.closePort();
		}
	}
}
