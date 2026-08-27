package com.digitalstables.paula.uploader;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.file.Files;
import java.nio.file.Paths;

import org.apache.commons.io.IOUtils;
import org.json.JSONArray;
import org.json.JSONObject;

// Calls the factory server's existing FactoryServlet the same way the webapp's own JS does -
// form-encoded POSTs with a formName parameter, JSON envelope back ({Status, Message, Data},
// where Data is itself a JSON string needing a second parse - same as afterlogin.js does).
// Plain java.net.HttpURLConnection rather than a new HTTP library: this codebase targets Java
// 8 (no java.net.http.HttpClient available), and GoogleCloudManager.java already establishes
// HttpURLConnection as this codebase's pattern for outbound REST calls - reusing it here rather
// than adding a new dependency for something already solved.
public class FactorySyncClient {

	private final String baseUrl;

	public FactorySyncClient(String baseUrl) {
		this.baseUrl = baseUrl;
	}

	public JSONArray pullPendingDeployments() throws IOException {
		JSONObject data = postForm("GetPendingDeployments", "");
		return data.getJSONArray("pendingDeployments");
	}

	public JSONArray pullLatestFirmwareList() throws IOException {
		JSONObject data = postForm("GetLatestFirmwareList", "");
		return data.getJSONArray("firmwareList");
	}

	public boolean downloadFirmwareBinary(int firmwareId, String file, String destPath) throws IOException {
		String query = "formName=DownloadFirmwareBinary&firmwareid=" + firmwareId + "&file=" + file;
		URL url = new URL(baseUrl + "/FactoryServlet?" + query);
		HttpURLConnection connection = (HttpURLConnection) url.openConnection();
		connection.setRequestMethod("GET");
		if (connection.getResponseCode() != 200) {
			System.out.println("Download failed, HTTP " + connection.getResponseCode());
			return false;
		}
		try (InputStream in = connection.getInputStream();
			 OutputStream out = Files.newOutputStream(Paths.get(destPath))) {
			IOUtils.copy(in, out);
		}
		connection.disconnect();
		return true;
	}

	// results is a JSONArray of {deploymentId, productId, success, firmwareId, firmwareVersion}
	public boolean pushResults(JSONArray results) throws IOException {
		postForm("ReportDeploymentResults", "&results=" + URLEncoder.encode(results.toString(), "UTF-8"));
		return true;
	}

	private JSONObject postForm(String formName, String extraParams) throws IOException {
		URL url = new URL(baseUrl + "/FactoryServlet");
		HttpURLConnection connection = (HttpURLConnection) url.openConnection();
		connection.setDoInput(true);
		connection.setDoOutput(true);
		connection.setRequestMethod("POST");
		connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");

		String payload = "formName=" + formName + extraParams;
		try (OutputStream os = connection.getOutputStream()) {
			os.write(payload.getBytes("UTF-8"));
		}

		StringBuilder responseText = new StringBuilder();
		try (BufferedReader br = new BufferedReader(new InputStreamReader(connection.getInputStream()))) {
			String line;
			while ((line = br.readLine()) != null) {
				responseText.append(line);
			}
		}
		connection.disconnect();

		JSONObject envelope = new JSONObject(responseText.toString());
		if (!"Success".equals(envelope.optString("Status"))) {
			throw new IOException(formName + " failed: " + envelope.optString("Message"));
		}
		return new JSONObject(envelope.getString("Data"));
	}
}
