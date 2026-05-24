%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        # Fixtures intentionally contain "crappy" shapes (the matrix under test);
        # do not lint them.
        excluded: [~r"/test/support/fixtures\.ex$"]
      },
      strict: true
    }
  ]
}
