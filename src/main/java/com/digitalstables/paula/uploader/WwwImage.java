package com.digitalstables.paula.uploader;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;

// A device's website (its data/ folder) ships as <repo>.www.bin - a LittleFS image built for the
// firmware's own "www" partition - sitting next to <repo>.ino.partitions.bin, and is flashed at
// whatever offset that partition has in that partition table. Never hardcode the offset: it
// belongs to the firmware release the image was built with. Optional - a release with no website
// simply has no .www.bin and this returns "" so the flash is exactly what it always was. Copied
// (not shared) from the factory webapp's WwwImage, same convention as the rest of this project.
public class WwwImage {

	public static final String LABEL = "www";
	private static final String PARTITIONS_SUFFIX = ".ino.partitions.bin";

	public static File imageFor(File partitionsBin){
		String name = partitionsBin.getName();
		if(!name.endsWith(PARTITIONS_SUFFIX)) return null;
		return new File(partitionsBin.getParentFile(), name.substring(0, name.length() - PARTITIONS_SUFFIX.length()) + ".www.bin");
	}

	// Offset of the "www" partition in the given partition table binary, or -1 if it has none.
	// Entries are 32 bytes: 0x50AA magic, type, subtype, offset (u32 LE), size (u32 LE), 16-byte
	// NUL-padded label, flags; the table ends at an MD5 entry (0xEBEB) or blank flash.
	public static long offsetOf(File partitionsBin) throws IOException{
		byte[] d = Files.readAllBytes(partitionsBin.toPath());
		for(int i = 0; i + 32 <= d.length; i += 32){
			if((d[i] & 0xFF) != 0xAA || (d[i + 1] & 0xFF) != 0x50) break;
			int labelStart = i + 12;
			int labelEnd = labelStart;
			while(labelEnd < i + 28 && d[labelEnd] != 0) labelEnd++;
			if(LABEL.equals(new String(d, labelStart, labelEnd - labelStart, "US-ASCII"))){
				return ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN).getInt(i + 4) & 0xFFFFFFFFL;
			}
		}
		return -1;
	}

	// The "0x<offset> <file>" write_flash pair for this release's website image, or "" if the
	// release has none. Refuses (rather than guessing) if an image exists but its firmware has no
	// www partition - flashing it anywhere else would overwrite something real.
	public static String writeFlashArgs(File partitionsBin) throws IOException{
		File wwwBin = imageFor(partitionsBin);
		if(wwwBin == null || !wwwBin.isFile()) return "";
		long offset = offsetOf(partitionsBin);
		if(offset < 0){
			throw new IOException(wwwBin.getName() + " exists but " + partitionsBin.getName() + " has no '" + LABEL + "' partition");
		}
		return "0x" + Long.toHexString(offset) + " \"" + wwwBin.getAbsolutePath() + "\"";
	}
}
