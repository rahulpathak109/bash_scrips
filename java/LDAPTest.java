/**
 * @see http://www.adamretter.org.uk/blog/entries/LDAPTest.java
 * <p>
 * java -Djavax.net.debug=ssl,keymanager -Djavax.net.ssl.trustStore=/path/to/truststore.jks LDAPTest "ldaps://ad.your-server.com:636" "dc=ad,dc=my-domain,dc=com" myLdapUsername myLdapPassword some_sAMAccountName
 * java -Djavax.net.debug=all LDAPTest "ldap://192.168.0.21:389" "dc=hdp,dc=localdomain" ldap@hdp.localdomain "$_LDAP_PASSWORD" ldap uid follow
 */

import java.util.Hashtable;
import javax.naming.Context;
import javax.naming.NamingEnumeration;
import javax.naming.NamingException;
import javax.naming.directory.DirContext;
import javax.naming.directory.SearchControls;
import javax.naming.directory.SearchResult;
import javax.naming.ldap.InitialLdapContext;
import javax.naming.ldap.LdapContext;

/**
 * Example code for retrieving a Users Primary Group
 * from Microsoft Active Directory via. its LDAP API
 *
 * @author Adam Retter <adam.retter@googlemail.com>
 */
public class LDAPTest {
    static String userSearchAttr = "sAMAccountName";
    //static String groupSearchAttr = "objectSid";

    /**
     * @param args the command line arguments
     */
    public static void main(String[] args) throws NamingException {

        final String ldapServer = args[0];
        final String ldapSearchBase = args[1];
        final String ldapUsername = args[2];
        final String ldapPassword = args[3];
        final String ldapAccountToLookup = args[4];

        if (args.length > 5) {
            userSearchAttr = args[5];
        }

        String referral = "ignore";
        if (args.length > 6) {
            referral = args[6];
        }

        Hashtable<String, Object> env = new Hashtable<String, Object>();
        env.put(Context.SECURITY_AUTHENTICATION, "simple");
        if (ldapUsername != null) {
            env.put(Context.SECURITY_PRINCIPAL, ldapUsername);
        }
        if (ldapPassword != null) {
            env.put(Context.SECURITY_CREDENTIALS, ldapPassword);
        }
        env.put(Context.INITIAL_CONTEXT_FACTORY, "com.sun.jndi.ldap.LdapCtxFactory");
        env.put(Context.PROVIDER_URL, ldapServer);

        // Set referral property; "ignore" is the default
        env.put(Context.REFERRAL, referral);

        //ensures that objectSID attribute values
        //will be returned as a byte[] instead of a String
        env.put("java.naming.ldap.attributes.binary", "objectSID");

        // the following is helpful in debugging errors
        env.put("com.sun.jndi.ldap.trace.ber", System.err);

        LdapContext ctx = new InitialLdapContext(env, null);

        LDAPTest ldap = new LDAPTest();

        //1) lookup the ldap account
        String searchFilter = "(&(" + userSearchAttr + "=" + ldapAccountToLookup + "))";
        SearchResult srLdapUser = ldap.findAccountByAccountName(ctx, ldapSearchBase, searchFilter);
        System.out.println("SearchResult=" + srLdapUser.toString());

        //2) get the SID of the users primary group
        //String primaryGroupSID = ldap.getPrimaryGroupSID(srLdapUser);

        //3) get the users Primary Group
        //String primaryGroupName = ldap.findGroupBySID(ctx, ldapSearchBase, primaryGroupSID);
        //System.out.println("primaryGroupName=" + primaryGroupName);
    }

    public SearchResult findAccountByAccountName(DirContext ctx, String ldapSearchBase, String searchFilter) throws NamingException {

        SearchControls searchControls = new SearchControls();
        searchControls.setSearchScope(SearchControls.SUBTREE_SCOPE);

        NamingEnumeration<SearchResult> results = ctx.search(ldapSearchBase, searchFilter, searchControls);

        SearchResult searchResult = null;
        if (results.hasMoreElements()) {
            searchResult = (SearchResult) results.nextElement();

            //make sure there is not another item available, there should be only 1 match
            if (results.hasMoreElements()) {
                System.err.println("Matched multiple users with the searchFilter: " + searchFilter);
                return null;
            }
        }

        return searchResult;
    }

    public NamingEnumeration searchAccount(DirContext ctx, String ldapSearchBase, String searchFilter) throws NamingException {

        SearchControls searchControls = new SearchControls();
        searchControls.setSearchScope(SearchControls.SUBTREE_SCOPE);

        NamingEnumeration<SearchResult> results = ctx.search(ldapSearchBase, searchFilter, searchControls);

        return results;
    }

    public String findGroupBySID(DirContext ctx, String ldapSearchBase, String sid) throws NamingException {

        String searchFilter = "(&(objectClass=group)(objectSid=" + sid + "))";

        SearchControls searchControls = new SearchControls();
        searchControls.setSearchScope(SearchControls.SUBTREE_SCOPE);

        NamingEnumeration<SearchResult> results = ctx.search(ldapSearchBase, searchFilter, searchControls);

        if (results.hasMoreElements()) {
            SearchResult searchResult = (SearchResult) results.nextElement();

            //make sure there is not another item available, there should be only 1 match
            if (results.hasMoreElements()) {
                System.err.println("Matched multiple groups for the group with SID: " + sid);
                return null;
            } else {
                return (String) searchResult.getAttributes().get(userSearchAttr).get();
            }
        }
        return null;
    }

    public String getPrimaryGroupSID(SearchResult srLdapUser) throws NamingException {
        byte[] objectSID = (byte[]) srLdapUser.getAttributes().get("objectSid").get();
        String strPrimaryGroupID = (String) srLdapUser.getAttributes().get("primaryGroupID").get();

        String strObjectSid = decodeSID(objectSID);

        return strObjectSid.substring(0, strObjectSid.lastIndexOf('-') + 1) + strPrimaryGroupID;
    }

    /**
     * The binary data is in the form:
     * byte[0] - revision level
     * byte[1] - count of sub-authorities
     * byte[2-7] - 48 bit authority (big-endian)
     * and then count x 32 bit sub authorities (little-endian)
     * <p>
     * The String value is: S-Revision-Authority-SubAuthority[n]...
     * <p>
     * Based on code from here - http://forums.oracle.com/forums/thread.jspa?threadID=1155740&tstart=0
     */
    public static String decodeSID(byte[] sid) {

        final StringBuilder strSid = new StringBuilder("S-");

        // get version
        final int revision = sid[0];
        strSid.append(Integer.toString(revision));

        //next byte is the count of sub-authorities
        final int countSubAuths = sid[1] & 0xFF;

        //get the authority
        long authority = 0;
        //String rid = "";
        for (int i = 2; i <= 7; i++) {
            authority |= ((long) sid[i]) << (8 * (5 - (i - 2)));
        }
        strSid.append("-");
        strSid.append(Long.toHexString(authority));

        //iterate all the sub-auths
        int offset = 8;
        int size = 4; //4 bytes for each sub auth
        for (int j = 0; j < countSubAuths; j++) {
            long subAuthority = 0;
            for (int k = 0; k < size; k++) {
                subAuthority |= (long) (sid[offset + k] & 0xFF) << (8 * k);
            }

            strSid.append("-");
            strSid.append(subAuthority);

            offset += size;
        }

        return strSid.toString();
    }
}