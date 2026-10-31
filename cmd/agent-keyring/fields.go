// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"context"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/joshp123/agent-keyring/internal/receiver"
)

func printFields(ctx context.Context, endpoint, tab string) error {
	output := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	if tab == "" {
		pages, err := receiver.Tabs(ctx, endpoint)
		if err != nil {
			return err
		}
		fmt.Fprintln(output, "TAB\tURL\tTITLE")
		for _, page := range pages {
			fmt.Fprintf(output, "%s\t%s\t%s\n", safe(page.ID), safe(page.URL), safe(page.Title))
		}
	} else {
		page, err := receiver.Fields(ctx, endpoint, tab)
		if err != nil {
			return err
		}
		fmt.Fprintln(output, "Page:", safe(page.URL))
		fmt.Fprintln(output, "Title:", safe(page.Title))
		fmt.Fprintln(output, "SELECTOR\tTYPE\tNAME\tID\tLABEL\tAUTOCOMPLETE")
		for _, field := range page.Controls {
			fmt.Fprintf(output, "%s\t%s\t%s\t%s\t%s\t%s\n", safe(field.Selector), safe(field.Type), safe(field.Name), safe(field.ID), safe(field.Label), safe(field.Autocomplete))
		}
		if len(page.Controls) == 0 {
			fmt.Fprintln(output, "No visible inputs or buttons.")
		}
	}
	return output.Flush()
}
