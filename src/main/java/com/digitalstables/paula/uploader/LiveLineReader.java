package com.digitalstables.paula.uploader;

import java.io.IOException;
import java.io.Reader;

// BufferedReader.readLine() only returns once a line is complete, but esptool prints its
// "Connecting........_____" progress dots with no newline until the connection attempt is over -
// so a line-at-a-time reader can't show them until it's too late to matter. This reads character
// by character, returns complete lines exactly as readLine() would (\n, \r and \r\n all end a
// line - esptool's "Writing at 0x... (12 %)" progress uses \r), and calls the listener with the
// still-incomplete line after every character so callers can show it live. Copied (not shared)
// into each project, same convention as the rest of this system.
public class LiveLineReader {

	public interface PartialListener {
		void onPartial(String partialLine);
	}

	private final Reader in;
	private final PartialListener listener;
	private boolean skipLf = false;

	public LiveLineReader(Reader in, PartialListener listener){
		this.in = in;
		this.listener = listener;
	}

	// Next complete line, or null at end of stream. A final line with no terminator is returned too.
	public String readLine() throws IOException{
		StringBuilder sb = new StringBuilder();
		int c;
		while((c = in.read()) != -1){
			if(c == '\n' && skipLf){
				skipLf = false;
				continue;
			}
			skipLf = false;
			if(c == '\r'){
				skipLf = true;
				return sb.toString();
			}
			if(c == '\n') return sb.toString();
			sb.append((char) c);
			if(listener != null) listener.onPartial(sb.toString());
		}
		return sb.length() > 0 ? sb.toString() : null;
	}

	public void close() throws IOException{
		in.close();
	}
}
