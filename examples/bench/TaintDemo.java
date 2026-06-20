package com.example.bench;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import javax.servlet.http.HttpServletRequest;

/**
 * Semgrep taint-mode fixture: one tainted source->sink path (vulnerable) and one
 * sanitized control path. The taint rule in scripts/semgrep-taint-demo.sh expects
 * exactly ONE finding -- the unsanitized query in vulnerable(). The sanitized()
 * method must NOT be reported, because sanitize() breaks the taint.
 *
 * This is the capability ast-grep cannot reach: ast-grep matches the syntactic
 * shape `$STMT.executeQuery(...)` in BOTH methods identically -- it has no notion
 * of whether the argument carries attacker-controlled data. Taint tracking does.
 */
public class TaintDemo {

    // VULNERABLE: user input flows unsanitized from getParameter into executeQuery.
    public ResultSet vulnerable(HttpServletRequest req, Connection conn) throws Exception {
        String user = req.getParameter("user");                 // source (tainted)
        String sql = "SELECT * FROM accounts WHERE name = '" + user + "'";
        Statement stmt = conn.createStatement();
        return stmt.executeQuery(sql);                          // sink (tainted) -> FINDING
    }

    // SAFE: the input is sanitized before reaching the sink, so taint is broken.
    public ResultSet sanitized(HttpServletRequest req, Connection conn) throws Exception {
        String user = req.getParameter("user");                 // source
        String safe = sanitize(user);                           // sanitizer breaks taint
        String sql = "SELECT * FROM accounts WHERE name = '" + safe + "'";
        Statement stmt = conn.createStatement();
        return stmt.executeQuery(sql);                          // sink (NOT tainted) -> no finding
    }

    private String sanitize(String s) {
        return s.replaceAll("[^a-zA-Z0-9]", "");
    }
}
