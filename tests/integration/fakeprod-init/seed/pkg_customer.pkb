CREATE OR REPLACE PACKAGE BODY pkg_customer AS
    PROCEDURE create_customer(
        p_customer_code IN customers.customer_code%TYPE,
        p_customer_name IN customers.customer_name%TYPE,
        p_email         IN customers.email%TYPE
    ) AS
    BEGIN
        INSERT INTO customers (customer_code, customer_name, email)
        VALUES (p_customer_code, p_customer_name, p_email);
    END create_customer;

    PROCEDURE deactivate_customer(
        p_customer_id IN customers.customer_id%TYPE
    ) AS
    BEGIN
        UPDATE customers
        SET status = 'INACTIVE'
        WHERE customer_id = p_customer_id;
    END deactivate_customer;

    FUNCTION get_customer_name(
        p_customer_id IN customers.customer_id%TYPE
    ) RETURN VARCHAR2
    AS
        v_customer_name customers.customer_name%TYPE;
    BEGIN
        SELECT customer_name
        INTO v_customer_name
        FROM customers
        WHERE customer_id = p_customer_id;
        RETURN v_customer_name;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END get_customer_name;
END pkg_customer;
/
