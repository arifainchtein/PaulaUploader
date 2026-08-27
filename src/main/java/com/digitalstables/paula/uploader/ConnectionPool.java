package com.digitalstables.paula.uploader;

import java.sql.Connection;
import java.sql.SQLException;

import org.apache.commons.dbcp2.BasicDataSource;

// Same shape as the factory webapp's persistence.ConnectionPool - copied rather than shared
// since this is a separate deployable project.
public class ConnectionPool extends BasicDataSource {

	public Connection getConnection() throws SQLException {
		return super.getConnection();
	}

	public void closeConnection(Connection con) throws SQLException {
		con.close();
	}
}
