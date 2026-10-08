CREATE OR REPLACE PACKAGE pkg_customer AS
    PROCEDURE create_customer(
        p_customer_code IN customers.customer_code%TYPE,
        p_customer_name IN customers.customer_name%TYPE,
        p_email         IN customers.email%TYPE
    );
    PROCEDURE deactivate_customer(
        p_customer_id IN customers.customer_id%TYPE
    );
    FUNCTION get_customer_name(
        p_customer_id IN customers.customer_id%TYPE
    ) RETURN VARCHAR2;
END pkg_customer;
/
