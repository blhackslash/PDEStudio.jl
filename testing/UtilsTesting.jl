using IPlotPDESols.Utils

#--- Example Usage (for testing in your environment) ---
function test_typed_parser()
    println("Testing typed tuple parser:")
    test_cases = [
        "(1.0, true, -3, 0.5)",
        "( 42,  false )",
        "()",
        "(42.0)",
        "(3.14,)",
        "(true)",
        "(true, )",
        "(1,2,false,)",
        " ( 1.0 , 2.0, true ) ",
        "not a tuple",
        "(abc)",
        "(1.0, abc, 3.0)",
        "(1.0,,2.0)",
        "(,)",
        "(1.0, false,,true)"
    ]

    for tc in test_cases
        result = StringToTuple(tc)
        if isnothing(result)
            println("Input: \"$tc\" -> Parsed: nothing")
        else
            types_str = join([typeof(el) for el in result], ", ")
            println("Input: \"$tc\" -> Parsed: $result (Types: ($types_str))")
        end
    end

    println("\nValidator example:")
    init_str_example = "(10.5, 7, false)"
    expected_type_signature = typeof(StringToTuple(init_str_example))
    println("Expected type signature from \"$init_str_example\": $expected_type_signature")

    function custom_validator(new_str::String, expected_sig::Type)
        parsed_tuple = StringToTuple(new_str)
        if isnothing(parsed_tuple)
            println("Validation for \"$new_str\": FAILED (parse error)")
            return false
        end
        if typeof(parsed_tuple) == expected_sig
            println("Validation for \"$new_str\": PASSED (is $expected_sig)")
            return true
        else
            println("Validation for \"$new_str\": FAILED (is $(typeof(parsed_tuple)), expected $expected_sig)")
            return false
        end
    end
    
    custom_validator("(1.0, 2, true)", expected_type_signature)
    custom_validator("(1.0, 2.0, true)", expected_type_signature) # Type mismatch for 2nd element
    custom_validator("(1.0, 2)", expected_type_signature)       # Length mismatch
    custom_validator("bad", expected_type_signature)
end

test_typed_parser()