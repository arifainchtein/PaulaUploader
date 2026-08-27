package com.digitalstables.paula.uploader;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

import org.json.JSONArray;
import org.json.JSONObject;

// Local Postgres on the Pi itself - not the factory server's database. Durable across power
// loss: every flash attempt is written the instant it happens, success or failure, so a dead
// battery mid-trip never loses a result. Same connection/PreparedStatement/manual-close style as
// the factory webapp's PostgresqlPersistenceManager, for consistency.
//
// One-time setup on the Pi (not automated - run once when provisioning it):
//   createdb paulauploader
//   psql paulauploader -c "create table pendingDeployment(id int primary key, productid int,
//     productname varchar(100), serialnumber varchar(50), firmwarerepositoryname varchar(100),
//     firmwareid int, firmwareversion int, binpath text, partitionspath text, downloadedon bigint);"
//   psql paulauploader -c "create table deploymentResult(id serial primary key, deploymentid int,
//     productid int, success boolean, firmwareid int, firmwareversion int, flashedon bigint,
//     reported boolean default false);"
public class DeploymentStore {

	private final ConnectionPool connectionPool;

	public DeploymentStore() {
		connectionPool = new ConnectionPool();
		connectionPool.setDriverClassName("org.postgresql.Driver");
		connectionPool.setUrl("jdbc:postgresql://127.0.0.1:5432/paulauploader");
		connectionPool.setUsername("paulauploader");
		connectionPool.setPassword("paulauploader");
		connectionPool.setMaxTotal(5);
		connectionPool.setInitialSize(1);
	}

	public void saveCurrentJob(int deploymentId, int productId, String productName, String serialNumber,
			String repositoryName, int firmwareId, int firmwareVersion, String binPath, String partitionsPath) {
		String sql = "delete from pendingDeployment";
		String insertSql = "insert into pendingDeployment(id, productid, productname, serialnumber, "
				+ "firmwarerepositoryname, firmwareid, firmwareversion, binpath, partitionspath, downloadedon) "
				+ "values(?,?,?,?,?,?,?,?,?,?)";
		Connection connection = null;
		PreparedStatement preparedStatement = null;
		try {
			connection = connectionPool.getConnection();
			preparedStatement = connection.prepareStatement(sql);
			preparedStatement.executeUpdate();
			preparedStatement.close();

			preparedStatement = connection.prepareStatement(insertSql);
			preparedStatement.setInt(1, deploymentId);
			preparedStatement.setInt(2, productId);
			preparedStatement.setString(3, productName);
			preparedStatement.setString(4, serialNumber);
			preparedStatement.setString(5, repositoryName);
			preparedStatement.setInt(6, firmwareId);
			preparedStatement.setInt(7, firmwareVersion);
			preparedStatement.setString(8, binPath);
			preparedStatement.setString(9, partitionsPath);
			preparedStatement.setLong(10, System.currentTimeMillis());
			preparedStatement.executeUpdate();
		} catch (SQLException e) {
			System.out.println("DeploymentStore.saveCurrentJob failed: " + e.getMessage());
		} finally {
			closeQuietly(preparedStatement, connection);
		}
	}

	public JSONObject getCurrentJob() {
		String sql = "select id, productid, productname, serialnumber, firmwarerepositoryname, firmwareid, firmwareversion, binpath, partitionspath from pendingDeployment limit 1";
		Connection connection = null;
		PreparedStatement preparedStatement = null;
		ResultSet rs = null;
		JSONObject toReturn = null;
		try {
			connection = connectionPool.getConnection();
			preparedStatement = connection.prepareStatement(sql);
			rs = preparedStatement.executeQuery();
			if (rs.next()) {
				toReturn = new JSONObject();
				toReturn.put("deploymentid", rs.getInt(1));
				toReturn.put("productid", rs.getInt(2));
				toReturn.put("productname", rs.getString(3));
				toReturn.put("serialnumber", rs.getString(4));
				toReturn.put("firmwarerepositoryname", rs.getString(5));
				toReturn.put("firmwareid", rs.getInt(6));
				toReturn.put("firmwareversion", rs.getInt(7));
				toReturn.put("binpath", rs.getString(8));
				toReturn.put("partitionspath", rs.getString(9));
			}
		} catch (SQLException e) {
			System.out.println("DeploymentStore.getCurrentJob failed: " + e.getMessage());
		} finally {
			if (rs != null) { try { rs.close(); } catch (SQLException e) { /* ignore */ } }
			closeQuietly(preparedStatement, connection);
		}
		return toReturn;
	}

	public void recordResult(int deploymentId, int productId, boolean success, int firmwareId, int firmwareVersion) {
		String sql = "insert into deploymentResult(deploymentid, productid, success, firmwareid, "
				+ "firmwareversion, flashedon, reported) values(?,?,?,?,?,?,false)";
		Connection connection = null;
		PreparedStatement preparedStatement = null;
		try {
			connection = connectionPool.getConnection();
			preparedStatement = connection.prepareStatement(sql);
			preparedStatement.setInt(1, deploymentId);
			preparedStatement.setInt(2, productId);
			preparedStatement.setBoolean(3, success);
			preparedStatement.setInt(4, firmwareId);
			preparedStatement.setInt(5, firmwareVersion);
			preparedStatement.setLong(6, System.currentTimeMillis());
			preparedStatement.executeUpdate();
		} catch (SQLException e) {
			System.out.println("DeploymentStore.recordResult failed: " + e.getMessage());
		} finally {
			closeQuietly(preparedStatement, connection);
		}
	}

	public JSONArray getUnreportedResults() {
		String sql = "select id, deploymentid, productid, success, firmwareid, firmwareversion from deploymentResult where reported=false";
		Connection connection = null;
		PreparedStatement preparedStatement = null;
		ResultSet rs = null;
		JSONArray toReturn = new JSONArray();
		try {
			connection = connectionPool.getConnection();
			preparedStatement = connection.prepareStatement(sql);
			rs = preparedStatement.executeQuery();
			while (rs.next()) {
				JSONObject obj = new JSONObject();
				obj.put("localId", rs.getInt(1));
				obj.put("deploymentId", rs.getInt(2));
				obj.put("productId", rs.getInt(3));
				obj.put("success", rs.getBoolean(4));
				obj.put("firmwareId", rs.getInt(5));
				obj.put("firmwareVersion", rs.getInt(6));
				toReturn.put(obj);
			}
		} catch (SQLException e) {
			System.out.println("DeploymentStore.getUnreportedResults failed: " + e.getMessage());
		} finally {
			if (rs != null) { try { rs.close(); } catch (SQLException e) { /* ignore */ } }
			closeQuietly(preparedStatement, connection);
		}
		return toReturn;
	}

	public void markReported(int localId) {
		String sql = "update deploymentResult set reported=true where id=?";
		Connection connection = null;
		PreparedStatement preparedStatement = null;
		try {
			connection = connectionPool.getConnection();
			preparedStatement = connection.prepareStatement(sql);
			preparedStatement.setInt(1, localId);
			preparedStatement.executeUpdate();
		} catch (SQLException e) {
			System.out.println("DeploymentStore.markReported failed: " + e.getMessage());
		} finally {
			closeQuietly(preparedStatement, connection);
		}
	}

	private void closeQuietly(PreparedStatement preparedStatement, Connection connection) {
		if (preparedStatement != null) {
			try { preparedStatement.close(); } catch (SQLException e) { /* ignore */ }
		}
		if (connection != null) {
			try { connectionPool.closeConnection(connection); } catch (SQLException e) { /* ignore */ }
		}
	}
}
