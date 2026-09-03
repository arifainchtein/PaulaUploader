package com.digitalstables.paula.uploader;

import java.io.FileWriter;
import java.io.IOException;

// Signals "press PROGRAM now" / "press RESET now" via the Pi's onboard ACT LED
// (/sys/class/leds/led0), for the single-device field scenario: Pi 3B + one Wally directly, no
// separate Paula controller, no screen. In that setup nobody is watching stdout over SSH when the
// prompt appears - the LED is the only physical signal available. Confirmed at the bench that
// Wally's current PCB rev has no auto-program/auto-reset circuitry (no transistors on the
// schematic), so a human pressing the button really is required every time; this can't be fixed
// in software until a future PCB revision adds that circuit (Continuity idea #6).
//
// Best-effort throughout: if led0 doesn't exist (different Pi model) or isn't writable (needs
// root, or udev rule granting access), every call silently no-ops rather than failing the flash
// over a missing status light. The println calls in FirmwareFlasher stay in place too, for the
// bench-testing-over-SSH case where a screen is available.
public class PiStatusLed {

	private static final String LED_PATH = "/sys/class/leds/led0/brightness";
	private static final String TRIGGER_PATH = "/sys/class/leds/led0/trigger";
	private static boolean triggerDisabled = false;

	// The default trigger (often "mmc0", SD card activity) fights manual brightness writes -
	// only needs doing once per process, best-effort like everything else here.
	private static void ensureManualControl() {
		if (triggerDisabled) return;
		triggerDisabled = true;
		write(TRIGGER_PATH, "none");
	}

	public static void on() {
		ensureManualControl();
		write(LED_PATH, "1");
	}

	public static void off() {
		ensureManualControl();
		write(LED_PATH, "0");
	}

	// Distinct patterns so the two esptool prompts don't look the same to an operator watching
	// the LED from across the room.
	public static void blinkForProgramPrompt() {
		blink(3, 500);
	}

	public static void blinkForResetPrompt() {
		blink(6, 150);
	}

	private static void blink(int times, int intervalMs) {
		for (int i = 0; i < times; i++) {
			on();
			sleep(intervalMs);
			off();
			sleep(intervalMs);
		}
	}

	private static void sleep(int ms) {
		try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
	}

	private static void write(String path, String value) {
		try (FileWriter w = new FileWriter(path)) {
			w.write(value);
		} catch (IOException e) {
			// best-effort, see class comment
		}
	}
}
