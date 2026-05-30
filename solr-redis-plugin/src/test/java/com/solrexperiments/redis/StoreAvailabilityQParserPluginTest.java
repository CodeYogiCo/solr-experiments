package com.solrexperiments.redis;

import org.apache.lucene.search.Query;
import org.apache.solr.common.params.ModifiableSolrParams;
import org.apache.solr.common.params.SolrParams;
import org.apache.solr.search.QParser;
import org.apache.solr.search.SyntaxError;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for the filter path ({@link StoreAvailabilityQParserPlugin}):
 * parameter validation, bitmap-key construction, and post-filter contract
 * (non-cached, cost >= 100). The per-document collection logic needs a real
 * index and is covered by the integration smoke test.
 */
class StoreAvailabilityQParserPluginTest {

    private Query parse(SolrParams localParams) throws SyntaxError {
        StoreAvailabilityQParserPlugin plugin = new StoreAvailabilityQParserPlugin();
        QParser qp = plugin.createParser("", localParams, new ModifiableSolrParams(), null);
        return qp.parse();
    }

    @Test
    void missingStoreId_throwsSyntaxError() {
        assertThrows(SyntaxError.class, () -> parse(new ModifiableSolrParams()));
    }

    @Test
    void buildsBitmapKeyFromStoreId() throws SyntaxError {
        ModifiableSolrParams lp = new ModifiableSolrParams();
        lp.set(StoreAvailabilityQParserPlugin.PARAM_STORE_ID, "1234");

        Query q = parse(lp);
        assertInstanceOf(StoreAvailabilityQParserPlugin.StoreAvailabilityPostFilter.class, q);
        var pf = (StoreAvailabilityQParserPlugin.StoreAvailabilityPostFilter) q;
        assertEquals("store:1234:availability", pf.bitmapKey());
    }

    @Test
    void postFilterIsNonCachedAndHighCost() throws SyntaxError {
        ModifiableSolrParams lp = new ModifiableSolrParams();
        lp.set(StoreAvailabilityQParserPlugin.PARAM_STORE_ID, "1234");

        var pf = (StoreAvailabilityQParserPlugin.StoreAvailabilityPostFilter) parse(lp);
        assertFalse(pf.getCache(), "post-filter must not be cached as a normal filter");
        assertTrue(pf.getCost() >= StoreAvailabilityQParserPlugin.POST_FILTER_COST,
                "post-filter cost must be >= 100 to run after cheaper filters");
    }
}
