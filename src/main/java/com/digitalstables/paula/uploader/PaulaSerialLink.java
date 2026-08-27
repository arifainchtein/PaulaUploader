package com.digitalstables.paula.uploader;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;

import com.fazecast.jSerialComm.SerialPort;

// Talks to Paula's ESP32 over the Wally carrier board's onboard CP2104 USB-UART chip. Same
// bounded-poll pattern as the factory webapp's SendOneCommandToSerialPort (rewritten off RXTX
// 2026-07-30 for exactly this reason - a device that never responds must not hang the caller
// forever), reimplemented here because this is a separate deployable project on the Pi, not
// something that can import the factory webapp's classes directly.
public class PaulaSerialLink {

	// Silicon Labs CP2104 - identifies Wally's port reliably regardless of enumeration order,
	// and disambiguates it from whatever port the target device being flashed shows up as, now
	// that the Pi has several serial-capable USB devices plugged in at once.
	private static final int WALLY_VENDOR_ID = 0x10C4;
	private static final int WALLY_PRODUCT_ID = 0xEA60;

	private static final int DATA_RATE = 115200;
	private static final int READ_TIMEOUT_MILLISECONDS = 500;
	private static final int MAX_WAIT_MILLISECONDS = 30000;

	public static SerialPort findWallyPort() {
		for (SerialPort port : SerialPort.getCommPorts()) {
			if (port.getVendorID() == WALLY_VENDOR_ID && port.getProductID() == WALLY_PRODUCT_ID) {
				return port;
			}
		}
		return null;
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

	// Sends a command and returns every line Paula replied with (data line(s) plus the final
	// Ok/Failure acknowledgement), newline-joined - callers that only care about the
	// acknowledgement can just check the result contains "Ok", but commands like GetSwitchState
	// that reply with a data line before the acknowledgement need the whole transcript, not just
	// the last line (this used to return only the last line, silently dropping the data).
	public String sendCommand(String command) {
		SerialPort port = findWallyPort();
		if (port == null) {
			System.out.println("Wally not found on any USB port - is it plugged in?");
			return null;
		}

		port.setComPortParameters(DATA_RATE, 8, SerialPort.ONE_STOP_BIT, SerialPort.NO_PARITY);
		port.setComPortTimeouts(SerialPort.TIMEOUT_READ_SEMI_BLOCKING, READ_TIMEOUT_MILLISECONDS, 0);

		if (!port.openPort()) {
			System.out.println("Failed to open Wally's serial port " + port.getSystemPortName());
			return null;
		}

		BufferedReader input = new BufferedReader(new InputStreamReader(port.getInputStream()));
		BufferedWriter output = new BufferedWriter(new OutputStreamWriter(port.getOutputStream()));
		try {
			output.write(command, 0, command.length());
			Thread.sleep(100);
			output.flush();

			StringBuilder transcript = new StringBuilder();
			long deadline = System.currentTimeMillis() + MAX_WAIT_MILLISECONDS;
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
				Thread.sleep(200);
			}
			System.out.println("Timed out waiting for Paula's response to " + command);
			return null;
		} catch (IOException | InterruptedException e) {
			System.out.println("Error talking to Wally: " + e.getMessage());
			return null;
		} finally {
			try { input.close(); } catch (IOException e) { /* ignore */ }
			try { output.close(); } catch (IOException e) { /* ignore */ }
			port.closePort();
		}
	}
}
